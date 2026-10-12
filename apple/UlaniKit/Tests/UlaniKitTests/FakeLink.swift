import Foundation
import os
@testable import UlaniKit

/// A calendar behind a fake GATT link: `FakeGatt` of python/tests/test_client.py, plus
/// stored CRCs (header-only probes), a data-start timeout and disconnects.
///
/// Every piece of state lives in one `OSAllocatedUnfairLock`, so the class is checked
/// `Sendable` (no `@unchecked`). Replies are never delivered from inside the write that
/// caused them: each one is yielded by its own `Task`, chained to the previous one so
/// notifications keep their order, like real notifications arriving a moment later.
final class FakeLink: GattLink {
    struct Write: Equatable, Sendable {
        let characteristic: GattCharacteristic
        let data: Data
    }

    struct State: Sendable {
        // Options (FakeGatt's constructor arguments and a few more).
        /// Largest write-without-response payload (FakeGatt: mtu - 3).
        var writeLength = 244
        /// Fixed answer to every image header; nil: `01 02` when `storedCRC[page]` equals
        /// the header's CRC32, otherwise `01 00`.
        var headerReply: Data?
        /// Answer once all announced data has arrived (unless the page is in `failPages`).
        var dataReply = Reply.dataOK
        var unlockReply = Reply.unlockOK
        /// Opcodes the device ignores.
        var silentOpcodes: Set<UInt8> = []
        /// Unrelated notification sent on the same characteristic just before each real reply.
        var stray: Data?
        /// Report `02 01` after this many image packets in total (the device gave up early).
        var failAfterPackets: Int?
        /// Ignore this many image headers (the device is refreshing and stays silent).
        var silentHeaders = 0
        /// Answer this many image headers with `01 01` (busy).
        var busyHeaders = 0
        /// Ignore every image header for these pages.
        var silentPages: Set<Int> = []
        /// Answer every image header for these pages with `01 01` (busy).
        var busyPages: Set<Int> = []
        /// Ignore this many status queries (`0C 00`).
        var silentSlotQueries = 0
        /// Page on screen, reported by `0C`.
        var shown = 3
        /// After the page on screen is replaced, ignore every command (the panel refreshes).
        var refreshSilence = false
        /// After a panel refresh starts (the page on screen replaced, or another page shown),
        /// ignore this many commands.
        var quietAfterRefresh = 0
        /// Answer to `0B` (show a page).
        var showReply = Reply.showSlotOK
        /// Answer `02 01` for the data of these pages.
        var failPages: Set<Int> = []
        /// Link gone: every write and read throws `linkLost`.
        var dead = false
        /// Every write throws `FakeLinkBug`, an error UlaniKit does not know.
        var buggy = false
        /// CRC32 of the image each page holds; updated on `02 00`.
        var storedCRC: [Int: UInt32] = [:]
        /// After `01 00` without any data the device gives up with `02 01`. The default is
        /// the hardware's ~4 s: 1 s was not enough on a loaded CI runner, where parallel
        /// CPU-heavy tests delay the session's tasks. Probe tests shorten it.
        var dataStartTimeout: Duration? = .seconds(4)
        /// Notify `05 00` right after connecting, like the device.
        var greets = true
        /// Pause after each image chunk (a slow link); not cut short by cancellation, so
        /// only the session's `shouldStop` ends the stream early.
        var chunkDelay: Duration?

        // Device state.
        var refreshing = false
        /// Commands still to ignore after a refresh started (`quietAfterRefresh`).
        var quiet = 0
        var connected = true
        var currentPage: Int?
        var currentCRC: UInt32 = 0
        var expected = 0
        var received = 0
        var headerSerial = 0
        var awaitingData = false

        // Records.
        var writes: [Write] = []
        /// "w" per image write, "r" per read, in order.
        var log: [String] = []
        /// Pages of the headers that were answered `01 00`.
        var headerPages: [Int] = []
        /// "header N" for every image header answered other than busy, and "show N" for
        /// every accepted `0B`, in order.
        var steps: [String] = []
        /// Panel refreshes so far.
        var refreshes = 0
        var packets = 0
        /// How often `notifications` was asked for (the session must subscribe once).
        var subscriptions = 0
        var disconnects = 0
        /// `writes.count` when `disconnect()` was first called.
        var writesAtDisconnect: Int?
        var lastDelivery: Task<Void, Never>?
    }

    static let model = "P7320E-B"
    static let firmware = "v1.0.09"
    /// 11:22:33:44:55:66 / "SERIAL", like test_client.py: obviously not a real device.
    static let deviceInfoReply = Data([0x0A, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]) + Data("SERIAL".utf8)

    private let lock: OSAllocatedUnfairLock<State>
    private let stream: AsyncStream<GattNotification>
    private let continuation: AsyncStream<GattNotification>.Continuation

    init(_ configure: (inout State) -> Void = { _ in }) {
        var state = State()
        configure(&state)
        (stream, continuation) = AsyncStream.makeStream(of: GattNotification.self)
        if state.greets {
            continuation.yield(GattNotification(characteristic: .command, value: Reply.deviceReady))
        }
        lock = OSAllocatedUnfairLock(initialState: state)
    }

    // MARK: test access

    /// A copy of the whole state.
    var state: State { lock.withLock { $0 } }
    func update(_ body: @Sendable (inout State) -> Void) { lock.withLock(body) }

    var writes: [Write] { state.writes }
    var commandWrites: [Data] { writes.filter { $0.characteristic == .command }.map(\.data) }
    var imageWrites: [Data] { writes.filter { $0.characteristic == .image }.map(\.data) }
    var headers: [Data] { commandWrites.filter { $0.first == Opcode.imageHeader } }
    var log: String { state.log.joined() }

    /// Deliver a notification nobody asked for (e.g. a late reply).
    func inject(_ value: Data, on characteristic: GattCharacteristic) {
        lock.withLock { s in post(value, on: characteristic, &s) }
    }

    // MARK: GattLink

    var notifications: AsyncStream<GattNotification> {
        lock.withLock { $0.subscriptions += 1 }
        return stream
    }

    func maximumWriteLength() async -> Int { lock.withLock { $0.writeLength } }

    func writeCommand(_ data: Data) async throws {
        try lock.withLock { s in
            try Self.requireLink(s)
            s.writes.append(Write(characteristic: .command, data: data))
            let bytes = [UInt8](data)
            guard let op = bytes.first, !s.silentOpcodes.contains(op), !s.refreshing else { return }
            if s.quiet > 0 {
                s.quiet -= 1
                return
            }
            let reply: Data
            switch op {
            case Opcode.imageHeader:
                guard bytes.count == 13 else { return }
                let page = Int(bytes[5])
                if s.silentPages.contains(page) { return }
                if s.busyPages.contains(page) {
                    post(Reply.headerBusy, on: .command, &s)
                    return
                }
                if s.silentHeaders > 0 {
                    s.silentHeaders -= 1
                    return
                }
                if s.busyHeaders > 0 {
                    s.busyHeaders -= 1
                    post(Reply.headerBusy, on: .command, &s)
                    return
                }
                s.steps.append("header \(page)")
                let crc = bytes[7..<11].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                reply = s.headerReply ?? (s.storedCRC[page] == crc ? Reply.headerSameImage : Reply.headerOK)
                s.expected = Int(bytes[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                s.received = 0
                if reply == Reply.headerOK {
                    s.headerPages.append(page)
                    s.currentPage = page
                    s.currentCRC = crc
                    s.headerSerial += 1
                    s.awaitingData = true
                    scheduleGiveUp(&s)
                }
            case Opcode.unlock:
                reply = s.unlockReply
            case Opcode.battery:
                reply = Data([0x06, 0x04])
            case Opcode.getSlot:
                if s.silentSlotQueries > 0 {
                    s.silentSlotQueries -= 1
                    return
                }
                let crc = s.storedCRC[s.shown] ?? 0xDEAD_BEEF
                reply = Data([0x0C, UInt8(s.shown), UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF),
                              UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
            case Opcode.deviceInfo:
                reply = Self.deviceInfoReply
            case Opcode.disconnect:
                reply = Data([0x09, 0x00])
            case Opcode.showSlot:
                reply = s.showReply
                if reply == Reply.showSlotOK, bytes.count == 2 {
                    let page = Int(bytes[1])
                    s.steps.append("show \(page)")
                    if page != s.shown {
                        s.shown = page
                        s.refreshes += 1
                        s.quiet = s.quietAfterRefresh
                    }
                }
            default:
                return
            }
            if let stray = s.stray { post(stray, on: .command, &s) }
            post(reply, on: .command, &s)
        }
    }

    func read(_ characteristic: ReadableCharacteristic) async throws -> Data {
        try lock.withLock { s in
            try Self.requireLink(s)
            s.log.append("r")
            return Data((characteristic == .modelNumber ? Self.model : Self.firmware).utf8)
        }
    }

    func streamImage(_ data: Data, chunkSize: Int,
                     progress: @escaping @Sendable (Int, Int) -> Void,
                     shouldStop: @escaping @Sendable () -> Bool) async throws -> Int {
        var sent = 0
        for chunk in try Messages.chunks(data, size: chunkSize) {
            // Let pending notifications run (Python: asyncio.sleep(0) before each chunk).
            await Task.yield()
            if shouldStop() { break }
            try receiveImage(chunk)
            sent += chunk.count
            progress(sent, data.count)
            if let delay = lock.withLock({ $0.chunkDelay }) {
                try? await Task.sleep(for: delay)
            }
        }
        return sent
    }

    func disconnect() async {
        lock.withLock { s in
            s.disconnects += 1
            if s.writesAtDisconnect == nil { s.writesAtDisconnect = s.writes.count }
            s.connected = false
        }
        continuation.finish()
    }

    // MARK: device behaviour

    private func receiveImage(_ chunk: Data) throws {
        try lock.withLock { s in
            try Self.requireLink(s)
            s.writes.append(Write(characteristic: .image, data: chunk))
            s.log.append("w")
            s.packets += 1
            s.received += chunk.count
            s.awaitingData = false
            if let limit = s.failAfterPackets, s.packets == limit {
                post(Reply.dataFail, on: .image, &s)
            } else if s.received == s.expected {
                if let stray = s.stray { post(stray, on: .image, &s) }
                let failed = s.currentPage.map { s.failPages.contains($0) } ?? false
                let reply = failed ? Reply.dataFail : s.dataReply
                post(reply, on: .image, &s)
                if reply == Reply.dataOK, let page = s.currentPage {
                    s.storedCRC[page] = s.currentCRC
                    if page == s.shown {
                        s.refreshes += 1
                        s.quiet = s.quietAfterRefresh
                        if s.refreshSilence { s.refreshing = true }
                    }
                }
            }
        }
    }

    /// The device gives up with `02 01` when no data follows `01 00` in time.
    private func scheduleGiveUp(_ s: inout State) {
        guard let timeout = s.dataStartTimeout else { return }
        let serial = s.headerSerial
        Task {
            try? await Task.sleep(for: timeout)
            self.lock.withLock { s in
                guard s.headerSerial == serial, s.awaitingData, s.connected else { return }
                s.awaitingData = false
                s.expected = 0
                self.post(Reply.dataFail, on: .image, &s)
            }
        }
    }

    /// Queue a notification behind the previous one (call with the lock held).
    private func post(_ value: Data, on characteristic: GattCharacteristic, _ s: inout State) {
        let previous = s.lastDelivery
        let continuation = self.continuation
        let notification = GattNotification(characteristic: characteristic, value: value)
        s.lastDelivery = Task {
            await previous?.value
            continuation.yield(notification)
        }
    }

    private static func requireLink(_ s: State) throws {
        if s.buggy { throw FakeLinkBug() }
        if s.dead { throw UlaniError.linkLost("the fake link is dead") }
        if !s.connected { throw UlaniError.linkLost("disconnected") }
    }
}

/// Stands in for a programming error inside a link (Python test: TypeError).
struct FakeLinkBug: Error, Equatable {}

// MARK: - helpers shared by the session tests

extension SessionTiming {
    /// For paths that get an answer: the timeouts only cost time when they expire.
    static let test = SessionTiming(replyTimeout: .seconds(2), resultTimeout: .seconds(2),
                                    busyTimeout: .seconds(2), retryDelay: .milliseconds(10))

    /// For tests that wait out a silent device (Python's `_quick`). On a loaded machine
    /// (tests run in parallel; debug-build CRC16 of a frame takes ~0.2 s) a real reply can
    /// miss a 50 ms timeout. That only costs a retry, so `busy` is long when a test expects
    /// success; tests that expect `deviceBusy` pass a short one.
    static func quick(reply: Duration = .milliseconds(50), result: Duration = .seconds(2),
                      busy: Duration = .seconds(10), retry: Duration = .milliseconds(10)) -> SessionTiming {
        SessionTiming(replyTimeout: reply, resultTimeout: result, busyTimeout: busy, retryDelay: retry)
    }
}

/// A started session. A short reply timeout can miss the unlock reply on a loaded
/// machine, so `start()` is retried on `noReply` like CalendarConnector does (tests of
/// `start()` itself call it directly).
func startedSession(_ link: FakeLink, timing: SessionTiming = .test,
                    readBarrierEvery: Int? = nil) async throws -> CalendarSession {
    let session = CalendarSession(link: link, timing: timing, readBarrierEvery: readBarrierEvery)
    var attempts = 1
    while true {
        do {
            try await session.start()
            return session
        } catch UlaniError.noReply where attempts < 20 {
            attempts += 1
        }
    }
}

/// Polls `condition` until it holds; fails the test after `timeout`.
func waitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { throw TestTimeout() }
        try await Task.sleep(for: .milliseconds(1))
    }
}

struct TestTimeout: Error {}

/// A frame filled with one byte (distinct CRCs per page).
func filledFrame(_ byte: UInt8) -> Frame {
    try! Frame(bytes: Data(repeating: byte, count: Frame.byteCount))
}

/// A frame whose bytes count up (0, 1, ..., 255, 0, ...), so misplaced chunks show.
func patternFrame() -> Frame {
    try! Frame(bytes: Data((0..<Frame.byteCount).map { UInt8(truncatingIfNeeded: $0) }))
}
