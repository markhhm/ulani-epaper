import Foundation
import Network
import os
import Testing
@testable import UlaniKit

/// A stand-in for the relay on 127.0.0.1: accepts one client at a time and answers each
/// request line with whatever `respond` returns (JSON lines without the newline).
final class ScriptedRelay: Sendable {
    struct Request: Sendable {
        let id: Int?
        let op: String
        let line: String

        /// The request as a JSON object.
        var object: NSDictionary {
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? NSDictionary ?? [:]
        }
    }

    private struct State: Sendable {
        var client: NWConnection?
        var buffer = Data()
        var requests: [Request] = []
        var clients = 0
        var clientClosed = false
        var ready: CheckedContinuation<Void, any Error>?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ScriptedRelay")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let respond: @Sendable (Request) -> [String]

    /// `respond` answers each request; the default answers like the fake relay.
    init(respond: @escaping @Sendable (Request) -> [String] = ScriptedRelay.standard) async throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            state.withLock { $0.ready = continuation }
            listener.stateUpdateHandler = { [weak self] update in
                switch update {
                case .ready: self?.takeReady()?.resume()
                case .failed(let error), .waiting(let error): self?.takeReady()?.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit {
        listener.cancel()
        state.withLock { $0.client?.cancel() }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requests: [Request] { state.withLock { $0.requests } }
    var ops: [String] { requests.map(\.op) }
    var clients: Int { state.withLock { $0.clients } }
    /// The client closed its side (EOF) or the connection failed.
    var clientClosed: Bool { state.withLock { $0.clientClosed } }

    /// Send a line (an event) to the client now.
    func send(_ line: String) {
        state.withLock { $0.client }?.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    /// Drop the client's connection.
    func closeClient() {
        state.withLock { $0.client }?.cancel()
    }

    func connect(scanTimeout: Duration = .seconds(5), timeouts: RelayLink.Timeouts = .init()) async throws -> RelayLink {
        try await RelayLink.connect(host: "127.0.0.1", port: port, scanTimeout: scanTimeout, flushEvery: 10,
                                    timeouts: timeouts)
    }

    /// Answers like `python -m ulani_epaper.relay --fake` for the ops that need no device.
    static func standard(_ request: Request) -> [String] {
        let id = request.id.map(String.init) ?? "null"
        switch request.op {
        case "hello": return [#"{"id":\#(id),"ok":true,"relay":1,"fake":true}"#]
        case "connect", "write_length": return [#"{"id":\#(id),"ok":true,"write_length":244}"#]
        case "read": return [#"{"id":\#(id),"ok":true,"data":"76312e302e3039"}"#]
        default: return [#"{"id":\#(id),"ok":true}"#]
        }
    }

    private func takeReady() -> CheckedContinuation<Void, any Error>? {
        state.withLock { s in
            defer { s.ready = nil }
            return s.ready
        }
    }

    private func accept(_ connection: NWConnection) {
        state.withLock { s in
            s.client = connection
            s.clients += 1
            s.buffer = Data()
            s.clientClosed = false
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.consume(data, from: connection) }
            if isComplete || error != nil {
                self.state.withLock { $0.clientClosed = true }
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func consume(_ data: Data, from connection: NWConnection) {
        let lines = state.withLock { s -> [Data] in
            s.buffer.append(data)
            var lines: [Data] = []
            while let end = s.buffer.firstIndex(of: 0x0A) {
                lines.append(Data(s.buffer[s.buffer.startIndex..<end]))
                s.buffer.removeSubrange(s.buffer.startIndex...end)
            }
            return lines
        }
        for line in lines {
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            let request = Request(id: object["id"] as? Int, op: object["op"] as? String ?? "",
                                  line: String(decoding: line, as: UTF8.self))
            state.withLock { $0.requests.append(request) }
            for reply in respond(request) {
                connection.send(content: Data((reply + "\n").utf8), completion: .contentProcessed { _ in })
            }
        }
    }
}

/// RelayLink against a scripted relay: request ids, events, errors, cancellation, closing.
@Suite struct RelayLinkTests {
    @Test func connectSaysHelloThenConnects() async throws {
        let relay = try await ScriptedRelay()
        let link = try await relay.connect(scanTimeout: .seconds(7))
        #expect(relay.ops == ["hello", "connect"])
        #expect(relay.requests[1].object == ["id": relay.requests[1].id!, "op": "connect",
                                             "address": NSNull(), "scan_timeout": 7])
        #expect(link.isFake)
        #expect(await link.maximumWriteLength() == 244)
        #expect(relay.ops == ["hello", "connect"])  // the length from connect: no round trip before a stream
        await link.disconnect()
    }

    @Test func theWriteLengthIsAskedAgainOnlyBeforeTheMTUExchange() async throws {
        // 20 means the relay host had not negotiated the MTU yet; it can only grow, once.
        let relay = try await ScriptedRelay { request in
            request.op == "connect" ? [#"{"id":\#(request.id!),"ok":true,"write_length":20}"#]
                                    : ScriptedRelay.standard(request)
        }
        let link = try await relay.connect()
        #expect(await link.maximumWriteLength() == 244)
        #expect(relay.ops == ["hello", "connect", "write_length"])
        #expect(await link.maximumWriteLength() == 244)
        #expect(relay.ops.count == 3)
        await link.disconnect()
    }

    @Test func requestsAreMatchedById() async throws {
        // Answers out of order and with an unknown id: each request still gets its own answer.
        let relay = try await ScriptedRelay { request in
            guard request.op == "read" else { return ScriptedRelay.standard(request) }
            let id = request.id!
            let model = request.object["char"] as? String == "model_number"
            return [#"{"id":\#(id + 1000),"ok":true,"data":"00"}"#,
                    #"{"id":\#(id),"ok":true,"data":"\#(Data((model ? "P7320E-B" : "v1.0.09").utf8).hexString())"}"#]
        }
        let link = try await relay.connect()
        async let model = link.read(.modelNumber)
        async let firmware = link.read(.firmwareRevision)
        #expect(try await String(decoding: model, as: UTF8.self) == "P7320E-B")
        #expect(try await String(decoding: firmware, as: UTF8.self) == "v1.0.09")
        await link.disconnect()
    }

    @Test func writeCommandAndNotificationsInOrder() async throws {
        let relay = try await ScriptedRelay { request in
            var lines = ScriptedRelay.standard(request)
            if request.op == "connect" { lines.append(#"{"event":"notify","char":"command","data":"0500"}"#) }
            if request.op == "write" {
                lines.insert(#"{"event":"notify","char":"command","data":"0400"}"#, at: 0)
                lines.append(#"{"event":"notify","char":"image","data":"0200"}"#)
            }
            return lines
        }
        let link = try await relay.connect()
        try await link.writeCommand(Command.unlock)
        #expect(relay.requests.last?.object["data"] as? String == "044e42")
        #expect(relay.requests.last?.object["char"] as? String == "command")
        var received: [GattNotification] = []
        for await notification in link.notifications {
            received.append(notification)
            if received.count == 3 { break }
        }
        #expect(received == [GattNotification(characteristic: .command, value: Reply.deviceReady),
                             GattNotification(characteristic: .command, value: Reply.unlockOK),
                             GattNotification(characteristic: .image, value: Reply.dataOK)])
        await link.disconnect()
    }

    @Test func streamIsOneRequestWithProgress() async throws {
        let relay = try await ScriptedRelay { request in
            guard request.op == "stream" else { return ScriptedRelay.standard(request) }
            let id = request.id!
            return [#"{"event":"progress","id":\#(id),"sent":2300,"total":4000}"#,
                    #"{"event":"progress","id":\#(id + 1),"sent":5,"total":5}"#,  // another request's
                    #"{"event":"progress","id":\#(id),"sent":4000,"total":4000}"#,
                    #"{"id":\#(id),"ok":true,"sent":4000}"#]
        }
        let link = try await relay.connect()
        let progress = Recorder<[Int]>()
        let data = Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let sent = try await link.streamImage(data, chunkSize: 230, progress: { progress.append([$0, $1]) },
                                              shouldStop: { false })
        #expect(sent == 4000)
        #expect(progress.values == [[2300, 4000], [4000, 4000]])
        let request = try #require(relay.requests.last?.object)
        #expect(request["op"] as? String == "stream")
        #expect(request["data"] as? String == data.hexString())
        #expect(request["chunk"] as? Int == 230)
        #expect(request["flush_every"] as? Int == 10)
        await link.disconnect()
    }

    @Test func streamAsksShouldStopBeforeSending() async throws {
        // The calendar already gave up (02 01 arrived before the stream): send nothing. The
        // relay only stops on notifications that arrive after its stream started.
        let relay = try await ScriptedRelay()
        let link = try await relay.connect()
        let progress = Recorder<Int>()
        let sent = try await link.streamImage(filledFrame(1).bytes, chunkSize: 230,
                                              progress: { sent, _ in progress.append(sent) }, shouldStop: { true })
        #expect(sent == 0)
        #expect(progress.values.isEmpty)
        #expect(!relay.ops.contains("stream"))
        try await link.writeCommand(Command.unlock)  // still usable
        await link.disconnect()
    }

    @Test func aStreamTheCalendarEndedEarlyFailsTheUpload() async throws {
        // The relay stops its stream when the calendar answers 02 01 and reports what it sent.
        let relay = try await ScriptedRelay { request in
            let id = request.id!
            let data = request.object["data"] as? String ?? ""
            switch request.op {
            case "write" where data == "044e42":
                return ScriptedRelay.standard(request) + [#"{"event":"notify","char":"command","data":"0400"}"#]
            case "write" where data.hasPrefix("01"):
                return ScriptedRelay.standard(request) + [#"{"event":"notify","char":"command","data":"0100"}"#]
            case "stream":
                return [#"{"event":"progress","id":\#(id),"sent":2300,"total":\#(Frame.byteCount)}"#,
                        #"{"event":"notify","char":"image","data":"0201"}"#,
                        #"{"id":\#(id),"ok":true,"sent":2530}"#]
            default:
                return ScriptedRelay.standard(request)
            }
        }
        let link = try await relay.connect()
        let session = CalendarSession(link: link, timing: .test)
        try await session.start()
        let progress = Recorder<[Int]>()
        await #expect(throws: UlaniError.uploadFailed(page: 2, reply: Reply.dataFail)) {
            try await session.upload(patternFrame(), page: 2) { progress.append([$0, $1]) }
        }
        #expect(progress.values == [[2300, Frame.byteCount]])
        #expect(relay.ops.filter { $0 == "stream" }.count == 1)
        #expect(!relay.clientClosed)  // an answer from the calendar, not a broken link
        await link.disconnect()
    }

    @Test func anUnansweredRequestClosesTheLink() async throws {
        // A stalled tunnel: every waiting request fails with linkLost and the link closes.
        let relay = try await ScriptedRelay { request in
            ["write", "read"].contains(request.op) ? [] : ScriptedRelay.standard(request)
        }
        let link = try await relay.connect(timeouts: .init(request: .milliseconds(500)))
        let write = Task { try await link.writeCommand(Command.unlock) }
        let read = Task { try await link.read(.modelNumber) }
        let stalled: @Sendable (any Error) -> Bool = { error in
            guard case .linkLost(let message) = error as? UlaniError else { return false }
            return message.contains("did not answer")
        }
        await #expect(performing: { try await write.value }, throws: stalled)
        await #expect(performing: { try await read.value }, throws: stalled)
        try await waitUntil { relay.clientClosed }
        for await _ in link.notifications {}  // ended
        await #expect(throws: UlaniError.self) { try await link.writeCommand(Command.unlock) }
        await link.disconnect()
    }

    @Test func aStreamMayOutlastTheRequestTimeout() async throws {
        let relay = try await ScriptedRelay { request in
            request.op == "stream" ? [] : ScriptedRelay.standard(request)  // answered below, late
        }
        let link = try await relay.connect(timeouts: .init(request: .milliseconds(500), stream: .seconds(20)))
        let stream = Task {
            try await link.streamImage(Data(count: 460), chunkSize: 230, progress: { _, _ in }, shouldStop: { false })
        }
        try await waitUntil { relay.ops.last == "stream" }
        try await Task.sleep(for: .milliseconds(1200))
        relay.send(#"{"id":\#(relay.requests.last!.id!),"ok":true,"sent":460}"#)
        #expect(try await stream.value == 460)
        await link.disconnect()
    }

    @Test func disconnectIsBoundedWhenTheRelayDoesNotAnswer() async throws {
        let relay = try await ScriptedRelay { request in
            request.op == "disconnect" ? [] : ScriptedRelay.standard(request)
        }
        let link = try await relay.connect(timeouts: .init(close: .milliseconds(300)))
        let clock = ContinuousClock()
        let start = clock.now
        await link.disconnect()
        // Bounded by two 300 ms timers; without them disconnect would wait forever. The margin
        // is wide because CPU-heavy tests running in parallel can delay timer tasks by seconds.
        #expect(clock.now - start < .seconds(30))
        try await waitUntil { relay.clientClosed }
        #expect(relay.ops.last == "disconnect")
    }

    @Test func errorsAreUlaniErrors() async throws {
        let relay = try await ScriptedRelay { request in
            let id = request.id!
            switch request.op {
            case "write": return [#"{"id":\#(id),"ok":false,"error":"not connected to the device","kind":"link"}"#]
            case "read": return [#"{"id":\#(id),"ok":false,"error":"TimeoutError","kind":"timeout"}"#]
            default: return ScriptedRelay.standard(request)
            }
        }
        let link = try await relay.connect()
        await #expect(throws: UlaniError.linkLost("not connected to the device")) {
            try await link.writeCommand(Command.unlock)
        }
        // Not noReply: like Python, a GATT timeout is not retried as "the device is silent".
        await #expect(throws: UlaniError.linkLost("timed out on the relay (TimeoutError)")) {
            _ = try await link.read(.modelNumber)
        }
        await link.disconnect()
    }

    @Test func noCalendarIsNotFound() async throws {
        let relay = try await ScriptedRelay { request in
            request.op == "connect"
                ? [#"{"id":\#(request.id!),"ok":false,"error":"no e-paper device found","kind":"not_found"}"#]
                : ScriptedRelay.standard(request)
        }
        await #expect(throws: UlaniError.notFound) { _ = try await relay.connect() }
        try await waitUntil { relay.clientClosed }  // the failed link closed its connection
    }

    @Test func aBusyRelayRefusesTheClient() async throws {
        let relay = try await ScriptedRelay { _ in
            [#"{"id":null,"ok":false,"error":"the relay is busy: another client is connected","kind":"link"}"#]
        }
        await #expect(throws: UlaniError.linkLost("the relay is busy: another client is connected")) {
            _ = try await relay.connect()
        }
    }

    @Test func anotherRelayVersionIsRefused() async throws {
        let relay = try await ScriptedRelay { request in
            request.op == "hello" ? [#"{"id":\#(request.id!),"ok":true,"relay":2,"fake":true}"#]
                                  : ScriptedRelay.standard(request)
        }
        await #expect {
            _ = try await relay.connect()
        } throws: { error in
            guard case .protocolError(let message) = error as? UlaniError else { return false }
            return message.contains("version 2")
        }
        #expect(relay.ops == ["hello", "disconnect"])  // never connects the calendar
    }

    @Test func nothingListeningIsLinkLost() async throws {
        let port = try await ScriptedRelay().port  // the relay is gone once this returns
        try await Task.sleep(for: .milliseconds(50))
        await #expect {
            _ = try await RelayLink.connect(host: "127.0.0.1", port: port)
        } throws: { error in
            guard case .linkLost(let message) = error as? UlaniError else { return false }
            return message.contains("127.0.0.1:\(port)")
        }
    }

    @Test func cancellingTheStreamClosesTheConnection() async throws {
        // The relay streams on its side and stops only when its client goes away.
        let relay = try await ScriptedRelay { request in
            request.op == "stream" ? [#"{"event":"progress","id":\#(request.id!),"sent":2300,"total":192000}"#]
                                   : ScriptedRelay.standard(request)
        }
        let link = try await relay.connect()
        let progress = Recorder<Int>()
        let task = Task {
            try await link.streamImage(filledFrame(1).bytes, chunkSize: 230, progress: { sent, _ in progress.append(sent) },
                                       shouldStop: { false })
        }
        try await waitUntil { !progress.values.isEmpty }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await waitUntil { relay.clientClosed }
        await #expect(throws: UlaniError.self) { try await link.writeCommand(Command.unlock) }
        for await _ in link.notifications {}  // ended
        await link.disconnect()
    }

    @Test func aCancelledCommandLeavesTheLinkUsable() async throws {
        let relay = try await ScriptedRelay { request in
            request.op == "write" && request.object["data"] as? String == "0600" ? [] : ScriptedRelay.standard(request)
        }
        let link = try await relay.connect()
        let task = Task { try await link.writeCommand(Command.battery) }
        try await waitUntil { relay.ops.last == "write" }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await link.writeCommand(Command.unlock)
        #expect(!relay.clientClosed)
        await link.disconnect()
    }

    @Test func theRelayGoingAwayFailsWaitingRequests() async throws {
        let relay = try await ScriptedRelay { request in
            request.op == "write" ? [] : ScriptedRelay.standard(request)
        }
        let link = try await relay.connect()
        let task = Task { try await link.writeCommand(Command.unlock) }
        try await waitUntil { relay.ops.last == "write" }
        relay.closeClient()
        await #expect {
            try await task.value
        } throws: { error in
            if case .linkLost = error as? UlaniError { return true }
            return false
        }
        for await _ in link.notifications {}  // ended
        await #expect(throws: UlaniError.self) { _ = try await link.read(.modelNumber) }
    }

    @Test func aDroppedCalendarEndsTheNotifications() async throws {
        let relay = try await ScriptedRelay()
        let link = try await relay.connect()
        relay.send(#"{"event":"notify","char":"command","data":"0500"}"#)
        relay.send(#"{"event":"disconnected","reason":"the device dropped the link"}"#)
        var received: [GattNotification] = []
        for await notification in link.notifications { received.append(notification) }
        #expect(received == [GattNotification(characteristic: .command, value: Reply.deviceReady)])
        await link.disconnect()
    }

    @Test func disconnectAsksTheRelayThenCloses() async throws {
        let relay = try await ScriptedRelay()
        let link = try await relay.connect()
        await link.disconnect()
        #expect(relay.ops == ["hello", "connect", "disconnect"])
        #expect(relay.clientClosed)  // closed before disconnect() returned
        for await _ in link.notifications {}  // ended
        await link.disconnect()  // again: nothing to do
        #expect(relay.ops.count == 3)
        await #expect(throws: UlaniError.self) { try await link.writeCommand(Command.unlock) }
    }

    @Test func aSessionWorksOverTheLink() async throws {
        // The device side scripted by hand: unlock, then the battery query.
        let relay = try await ScriptedRelay { request in
            var lines = ScriptedRelay.standard(request)
            switch request.object["data"] as? String {
            case "044e42": lines.append(#"{"event":"notify","char":"command","data":"0400"}"#)
            case "0600": lines.append(#"{"event":"notify","char":"command","data":"0603"}"#)
            default: break
            }
            return lines
        }
        let link = try await relay.connect()
        let session = CalendarSession(link: link, timing: .test)
        try await session.start()
        #expect(try await session.battery() == Battery(level: 3, charging: false))
        #expect(try await session.firmware() == "v1.0.09")
        await link.disconnect()
    }
}
