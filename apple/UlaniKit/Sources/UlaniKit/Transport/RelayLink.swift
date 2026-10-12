import Foundation
import Network
import os

/// `GattLink` through the TCP relay (`python -m ulani_epaper.relay`): test UlaniKit against
/// a calendar next to another computer, or against the relay's `--fake` calendar.
///
/// Requests carry ids and the relay answers them in order (see `RelayCodec`);
/// notifications and stream progress arrive as events in between. The image stream runs
/// on the relay host, which paces the writes (a firmware-revision read every `flushEvery`
/// chunks) and stops as soon as the calendar answers on the image characteristic, so
/// `streamImage` is one request and asks `shouldStop` only once, before sending it (the
/// relay ignores answers that arrived before its stream started). Cancelling it closes the
/// connection, the only way to stop the relay's stream (the relay then also drops the
/// Bluetooth link). Progress is reported every 10 chunks, not after each one. Use the link
/// with `readBarrierEvery: nil`: the relay already has one.
///
/// Every piece of mutable state lives in one `OSAllocatedUnfairLock`; Network.framework
/// calls back on a private serial queue.
public final class RelayLink: GattLink {
    /// How long the link waits for the relay; when one runs out the link closes with
    /// `linkLost` (a stalled tunnel). Internal so tests can shorten them.
    struct Timeouts: Sendable {
        /// Longest wait for an answer; the relay bounds each Bluetooth operation by 30 s.
        var request: Duration = .seconds(60)
        /// Longest wait for a whole image stream (~30 s per page on hardware).
        var stream: Duration = .seconds(300)
        /// Longest wait for the relay to let go of us after `disconnect`.
        var close: Duration = .seconds(15)
    }

    /// Longest wait for the TCP connection, in seconds.
    static let openTimeout = 10
    /// Longest line the relay may send (its own request limit).
    static let lineLimit = 1 << 20
    /// Write length before the MTU exchange (23 - 3); the exchange happens at most once.
    static let minimumWriteLength = 20

    public let notifications: AsyncStream<GattNotification>
    /// Image chunks between firmware-revision reads on the relay host (0: none).
    public let flushEvery: Int

    private struct Pending: Sendable {
        let continuation: CheckedContinuation<RelayResult, any Error>
        let progress: (@Sendable (Int, Int) -> Void)?
        let timer: Task<Void, Never>
    }

    private struct State: Sendable {
        var lastID = 0
        var pending: [Int: Pending] = [:]
        /// Received bytes not yet split into lines.
        var buffer = Data()
        /// Why the connection is over; set once.
        var closed: UlaniError?
        /// `open()` waiting for the TCP connection.
        var opening: CheckedContinuation<Void, any Error>?
        /// `disconnect()` calls waiting for the relay to close its side.
        var closing: [CheckedContinuation<Void, Never>] = []
        var writeLength = 244
        var fake = false
    }

    /// "host:port", for messages.
    private let endpoint: String
    private let timeouts: Timeouts
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "UlaniKit.RelayLink")
    private let incoming: AsyncStream<GattNotification>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Connect to the relay at `host:port`, check it (`hello`) and let it connect the
    /// calendar (`connect`, scanning up to `scanTimeout`). Failures are UlaniErrors:
    /// `notFound` when the relay finds no calendar, `linkLost` when the relay cannot be
    /// reached, is busy with another client or loses the calendar.
    public static func connect(host: String, port: UInt16, scanTimeout: Duration = .seconds(30),
                               flushEvery: Int = 10) async throws -> RelayLink {
        try await connect(host: host, port: port, scanTimeout: scanTimeout, flushEvery: flushEvery,
                          timeouts: Timeouts())
    }

    static func connect(host: String, port: UInt16, scanTimeout: Duration, flushEvery: Int,
                        timeouts: Timeouts) async throws -> RelayLink {
        let link = RelayLink(host: host, port: port, flushEvery: flushEvery, timeouts: timeouts)
        do {
            try await link.open()
            let hello = try await link.request(.hello)
            guard hello.relay == 1 else {
                let version = hello.relay.map(String.init) ?? "unknown"
                throw UlaniError.protocolError("relay protocol version \(version) is not supported (expected 1)")
            }
            let connected = try await link.request(.connect(address: nil, scanTimeout: scanTimeout),
                                                   timeout: scanTimeout + timeouts.request)
            link.state.withLock { s in
                s.fake = hello.fake ?? false
                if let length = connected.writeLength { s.writeLength = length }
            }
            return link
        } catch {
            await link.disconnect()
            throw Task.isCancelled ? CancellationError() : error
        }
    }

    private init(host: String, port: UInt16, flushEvery: Int, timeouts: Timeouts) {
        endpoint = "\(host):\(port)"
        self.timeouts = timeouts
        self.flushEvery = max(0, flushEvery)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true  // one small line per command: no Nagle delay
        tcp.connectionTimeout = Self.openTimeout
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any,
                                  using: NWParameters(tls: nil, tcp: tcp))
        (notifications, incoming) = AsyncStream.makeStream(of: GattNotification.self)
    }

    deinit {
        connection.cancel()
        incoming.finish()
    }

    /// The relay drives its simulated calendar (`--fake`), not a real one.
    public var isFake: Bool { state.withLock { $0.fake } }

    // MARK: GattLink

    /// The write length `connect` reported. It is asked for again only while the relay host
    /// has not exchanged the MTU yet: that happens at most once per connection, and a round
    /// trip here delays the stream the calendar expects within ~4 s of `01 00`.
    public func maximumWriteLength() async -> Int {
        let cached = state.withLock { $0.writeLength }
        guard cached <= Self.minimumWriteLength,
              let length = try? await request(.writeLength).writeLength else { return cached }
        state.withLock { $0.writeLength = length }
        return length
    }

    public func writeCommand(_ data: Data) async throws {
        _ = try await request(.write(.command, data))
    }

    public func read(_ characteristic: ReadableCharacteristic) async throws -> Data {
        guard let data = try await request(.read(characteristic)).data else {
            throw UlaniError.protocolError("the relay answered a read without data")
        }
        return data
    }

    public func streamImage(_ data: Data, chunkSize: Int,
                            progress: @escaping @Sendable (Int, Int) -> Void,
                            shouldStop: @escaping @Sendable () -> Bool) async throws -> Int {
        // The calendar may have given up already; the relay would not notice.
        if shouldStop() { return 0 }
        let result = try await request(.stream(data, chunk: chunkSize, flushEvery: flushEvery),
                                       timeout: timeouts.stream, progress: progress)
        guard let sent = result.sent else {
            throw UlaniError.protocolError("the relay answered a stream without \"sent\"")
        }
        return sent
    }

    /// Ask the relay to drop the calendar, then close the connection and wait until the
    /// relay has let go of us (it refuses a new client until then). Bounded, never throws.
    public func disconnect() async {
        guard state.withLock({ $0.closed == nil }) else { return }
        _ = try? await request(.disconnect, timeout: timeouts.close)
        let timer = Task { [weak self, timeouts] in
            do { try await Task.sleep(for: timeouts.close) } catch { return }
            self?.close(.linkLost("disconnected"))
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = state.withLock { s in
                guard s.closed == nil else { return false }
                s.closing.append(continuation)
                return true
            }
            guard open else { return continuation.resume() }
            // Half-close: the relay sees EOF, cleans up and closes its side.
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in })
        }
        timer.cancel()
        close(.linkLost("disconnected"))
    }

    // MARK: requests

    /// Send `request` and wait for its answer. An error answer is thrown as UlaniError.
    /// Cancelling abandons the request (a late answer is ignored), except a stream:
    /// that closes the connection.
    private func request(_ request: RelayRequest, timeout: Duration? = nil,
                         progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> RelayResult {
        let timeout = timeout ?? timeouts.request
        let id = state.withLock { s in
            s.lastID += 1
            return s.lastID
        }
        let line = try RelayCodec.encode(request, id: id)
        let isStream = if case .stream = request { true } else { false }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.close(.linkLost("the relay did not answer within \(timeout)"))
                }
                let closed = state.withLock { s -> UlaniError? in
                    if let closed = s.closed { return closed }
                    s.pending[id] = Pending(continuation: continuation, progress: progress, timer: timer)
                    return nil
                }
                if let closed {
                    timer.cancel()
                    return continuation.resume(throwing: closed)
                }
                if Task.isCancelled {  // the cancellation handler may have run before we registered
                    return cancel(id, closing: isStream)
                }
                connection.send(content: line, completion: .contentProcessed { [weak self] error in
                    if let error { self?.close(.linkLost("sending to the relay failed: \(error)")) }
                })
            }
        } onCancel: {
            cancel(id, closing: isStream)
        }
    }

    private func cancel(_ id: Int, closing: Bool) {
        guard let pending = state.withLock({ $0.pending.removeValue(forKey: id) }) else { return }
        pending.timer.cancel()
        pending.continuation.resume(throwing: CancellationError())
        if closing { close(.linkLost("the image stream was cancelled")) }
    }

    private func answer(_ id: Int, _ result: Result<RelayResult, UlaniError>) {
        // Unknown ids belong to abandoned requests.
        guard let pending = state.withLock({ $0.pending.removeValue(forKey: id) }) else { return }
        pending.timer.cancel()
        pending.continuation.resume(with: result)
    }

    // MARK: connection

    private func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let closed = state.withLock { s -> UlaniError? in
                    if let closed = s.closed { return closed }
                    s.opening = continuation
                    return nil
                }
                if let closed { return continuation.resume(throwing: closed) }
                connection.stateUpdateHandler = { [weak self] update in self?.connectionChanged(update) }
                connection.start(queue: queue)
            }
        } onCancel: {
            close(.linkLost("cancelled"))
        }
    }

    private func connectionChanged(_ update: NWConnection.State) {
        switch update {
        case .ready:
            let opening = state.withLock { s in
                defer { s.opening = nil }
                return s.opening
            }
            opening?.resume()
            receive()
        case .waiting(let error):
            // Refused or unreachable: fail now instead of waiting for the network to change.
            close(.linkLost("cannot reach the relay at \(endpoint): \(error)"))
        case .failed(let error):
            close(.linkLost("the connection to the relay at \(endpoint) failed: \(error)"))
        case .cancelled:
            close(.linkLost("the connection to the relay was closed"))
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { consume(data) }
            if let error {
                close(.linkLost("the connection to the relay failed: \(error)"))
            } else if isComplete {
                close(.linkLost("the relay closed the connection"))
            } else {
                receive()
            }
        }
    }

    /// Split received bytes into lines and handle each.
    private func consume(_ data: Data) {
        let lines = state.withLock { s -> [Data]? in
            guard s.closed == nil else { return [] }
            s.buffer.append(data)
            var lines: [Data] = []
            while let end = s.buffer.firstIndex(of: 0x0A) {
                lines.append(Data(s.buffer[s.buffer.startIndex..<end]))
                s.buffer.removeSubrange(s.buffer.startIndex...end)
            }
            return s.buffer.count > Self.lineLimit ? nil : lines
        }
        guard let lines else {
            return close(.protocolError("the relay sent a line longer than \(Self.lineLimit) bytes"))
        }
        for line in lines where line.contains(where: { $0 != 0x20 && $0 != 0x0D }) {
            do {
                handle(try RelayCodec.decode(line))
            } catch {
                return close(UlaniError.from(error) ?? .protocolError("\(error)"))
            }
        }
    }

    private func handle(_ message: RelayMessage) {
        switch message {
        case .success(let id?, let result):
            answer(id, .success(result))
        case .failure(let id?, let failure):
            answer(id, .failure(failure.ulaniError))
        case .failure(nil, let failure):
            // The relay refused us (busy with another client) or could not read a request.
            close(failure.ulaniError)
        case .notify(let notification):
            incoming.yield(notification)
        case .progress(let id?, let sent, let total):
            state.withLock { $0.pending[id]?.progress }?(sent, total)
        case .disconnected:
            // The calendar is gone; waiting replies fail with linkLost. Requests still get
            // answers (errors) from the relay.
            incoming.finish()
        case .success(nil, _), .progress(nil, _, _), .unknownEvent:
            break
        }
    }

    /// The connection is over: fail everything still waiting with `error`, end the
    /// notifications and cancel the connection. Only the first call counts.
    private func close(_ error: UlaniError) {
        let waiting = state.withLock { s -> (pending: [Pending], opening: CheckedContinuation<Void, any Error>?,
                                            closing: [CheckedContinuation<Void, Never>])? in
            guard s.closed == nil else { return nil }
            s.closed = error
            defer {
                s.pending = [:]
                s.opening = nil
                s.closing = []
                s.buffer = Data()
            }
            return (Array(s.pending.values), s.opening, s.closing)
        }
        guard let waiting else { return }
        connection.cancel()
        incoming.finish()
        for pending in waiting.pending {
            pending.timer.cancel()
            pending.continuation.resume(throwing: error)
        }
        waiting.opening?.resume(throwing: error)
        for continuation in waiting.closing { continuation.resume() }
    }
}
