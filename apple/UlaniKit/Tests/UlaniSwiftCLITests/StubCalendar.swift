import Foundation
import os
import UlaniKit

/// A calendar for the CLI tests: just enough of the protocol for info, show, push and probe.
/// Its pages survive reconnects; every `link()` is a new connection to it. All state sits
/// in one lock; replies are yielded right after the write that caused them.
final class StubCalendar: Sendable {
    struct State: Sendable {
        var shown = 1
        /// CRC32 of the image each page holds.
        var stored: [Int: UInt32] = [:]
        /// Answer `02 01` for the data of these pages.
        var failPages: Set<Int> = []
        /// Answer `0B 01` to `0B SS`.
        var rejectShow = false
        /// Replies (by opcode) never sent; 0x02 is the upload result.
        var silent: Set<UInt8> = []
        var commands: [Data] = []
        var imageBytes = 0
        var connects = 0
        var disconnects = 0
        var firmwareReads = 0
        // Upload in progress.
        var page: Int?
        var crc: UInt32 = 0
        var expected = 0
        var received = 0
        var headerSerial = 0
        var awaitingData = false
    }

    static let deviceInfo = Data([0x0A, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01]) + Data("STUB0001".utf8)
    /// The device gives up this long after `01 00` when no data follows. Like the hardware
    /// (~4 s): 1 s was not enough on a loaded CI runner.
    static let dataStartTimeout = Duration.seconds(4)

    private let lock: OSAllocatedUnfairLock<State>

    init(_ configure: (inout State) -> Void = { _ in }) {
        var state = State()
        configure(&state)
        lock = OSAllocatedUnfairLock(initialState: state)
    }

    var state: State { lock.withLock { $0 } }

    /// A new connection.
    func link() -> StubLink {
        lock.withLock { $0.connects += 1 }
        return StubLink(calendar: self)
    }

    /// The reply to `command` on the command characteristic, if any.
    fileprivate func handle(_ command: Data, from link: StubLink) -> Data? {
        lock.withLock { s in
            s.commands.append(command)
            let bytes = [UInt8](command)
            if let opcode = bytes.first, s.silent.contains(opcode) { return nil }
            switch bytes.first {
            case 0x01 where bytes.count == 13:
                let page = Int(bytes[5])
                let crc = bytes[7..<11].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                if s.stored[page] == crc { return Data([0x01, 0x02]) }
                s.page = page
                s.crc = crc
                s.expected = Int(bytes[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                s.received = 0
                s.headerSerial += 1
                s.awaitingData = true
                let serial = s.headerSerial
                Task {
                    try? await Task.sleep(for: Self.dataStartTimeout)
                    let gaveUp = self.lock.withLock { s in
                        guard s.headerSerial == serial, s.awaitingData else { return false }
                        s.awaitingData = false
                        return true
                    }
                    if gaveUp { link.notify(Data([0x02, 0x01]), on: .image) }
                }
                return Data([0x01, 0x00])
            case 0x04: return Data([0x04, 0x00])
            case 0x06: return Data([0x06, 0x04])
            case 0x09: return Data([0x09, 0x00])
            case 0x0A: return Self.deviceInfo
            case 0x0B where bytes.count == 2 && Panel.userSlots.contains(Int(bytes[1])):
                if s.rejectShow { return Data([0x0B, 0x01]) }
                s.shown = Int(bytes[1])
                return Data([0x0B, 0x00])
            case 0x0C:
                let crc = s.stored[s.shown] ?? 0
                return Data([0x0C, UInt8(s.shown), UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF),
                             UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
            default: return nil
            }
        }
    }

    fileprivate func record(_ change: @Sendable (inout State) -> Void) {
        lock.withLock { change(&$0) }
    }

    /// Image data arrived; the result once the announced length is complete.
    fileprivate func receive(_ chunk: Data) -> Data? {
        lock.withLock { s in
            s.imageBytes += chunk.count
            s.awaitingData = false
            s.received += chunk.count
            guard s.received == s.expected, let page = s.page, !s.silent.contains(0x02) else { return nil }
            s.page = nil
            if s.failPages.contains(page) { return Data([0x02, 0x01]) }
            s.stored[page] = s.crc
            return Data([0x02, 0x00])
        }
    }
}

/// One connection to a `StubCalendar`.
final class StubLink: GattLink {
    let notifications: AsyncStream<GattNotification>
    private let continuation: AsyncStream<GattNotification>.Continuation
    private let calendar: StubCalendar

    fileprivate init(calendar: StubCalendar) {
        self.calendar = calendar
        (notifications, continuation) = AsyncStream.makeStream(of: GattNotification.self)
        notify(Data([0x05, 0x00]), on: .command)
    }

    func notify(_ value: Data, on characteristic: GattCharacteristic) {
        continuation.yield(GattNotification(characteristic: characteristic, value: value))
    }

    func maximumWriteLength() async -> Int { 244 }

    func writeCommand(_ data: Data) async throws {
        if let reply = calendar.handle(data, from: self) { notify(reply, on: .command) }
    }

    func read(_ characteristic: ReadableCharacteristic) async throws -> Data {
        if characteristic == .firmwareRevision { calendar.record { $0.firmwareReads += 1 } }
        return Data((characteristic == .modelNumber ? "P7320E-B" : "v1.0.09").utf8)
    }

    func streamImage(_ data: Data, chunkSize: Int, progress: @escaping @Sendable (Int, Int) -> Void,
                     shouldStop: @escaping @Sendable () -> Bool) async throws -> Int {
        var sent = 0
        for chunk in try Messages.chunks(data, size: chunkSize) {
            await Task.yield()
            if shouldStop() { break }
            let result = calendar.receive(chunk)
            sent += chunk.count
            progress(sent, data.count)
            if let result { notify(result, on: .image) }
        }
        return sent
    }

    func disconnect() async {
        calendar.record { $0.disconnects += 1 }
        continuation.finish()
    }
}
