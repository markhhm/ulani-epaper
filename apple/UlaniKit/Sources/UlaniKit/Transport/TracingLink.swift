import Foundation

/// A `GattLink` that reports every command, reply and read to `log` as hex, annotated
/// with what it means (`ulani-swift --verbose`, for debugging on hardware). Image data is
/// summarised per stream, not dumped. Wraps any link; the session uses it like the link.
///
/// Lines: `-> command 04 4e 42  (unlock)`, `<- command 04 00  (unlocked)`,
/// `-> read firmware revision`, `<- firmware revision 76 31 ...  ("v1.0.09")`,
/// `-> image 192000 bytes in 230-byte chunks`, `-- image stream sent ...`, `!! ... failed: ...`.
/// Replies are logged before the session sees them. `log` is called from any task.
public final class TracingLink: GattLink {
    public let notifications: AsyncStream<GattNotification>
    private let link: any GattLink
    private let log: @Sendable (String) -> Void
    /// Logs and forwards the wrapped link's notifications.
    private let forwarder: Task<Void, Never>

    public init(_ link: any GattLink, log: @escaping @Sendable (String) -> Void) {
        self.link = link
        self.log = log
        let (stream, continuation) = AsyncStream.makeStream(of: GattNotification.self)
        notifications = stream
        let source = link.notifications
        forwarder = Task {
            for await notification in source {
                log(Self.line("<-", notification.characteristic, notification.value, outgoing: false))
                continuation.yield(notification)
            }
            log("-- notifications ended")
            continuation.finish()
        }
    }

    deinit {
        forwarder.cancel()
    }

    public func maximumWriteLength() async -> Int {
        let length = await link.maximumWriteLength()
        log("-- write length \(length)")
        return length
    }

    public func writeCommand(_ data: Data) async throws {
        let line = Self.line("->", .command, data, outgoing: true)
        log(line)
        do {
            try await link.writeCommand(data)
        } catch {
            log("!! command \(data.hexString(separator: " ")) failed: \(error)")
            throw error
        }
    }

    public func read(_ characteristic: ReadableCharacteristic) async throws -> Data {
        let name = Self.name(characteristic)
        log("-> read \(name)")
        do {
            let value = try await link.read(characteristic)
            var line = "<- \(name) \(value.hexString(separator: " "))"
            if !value.isEmpty, value.allSatisfy({ (0x20..<0x7F).contains($0) }) {
                line += "  (\"\(String(decoding: value, as: UTF8.self))\")"
            }
            log(line)
            return value
        } catch {
            log("!! read \(name) failed: \(error)")
            throw error
        }
    }

    public func streamImage(_ data: Data, chunkSize: Int,
                            progress: @escaping @Sendable (Int, Int) -> Void,
                            shouldStop: @escaping @Sendable () -> Bool) async throws -> Int {
        log("-> image \(data.count) bytes in \(chunkSize)-byte chunks")
        do {
            let sent = try await link.streamImage(data, chunkSize: chunkSize, progress: progress,
                                                  shouldStop: shouldStop)
            log(sent < data.count
                ? "-- image stream stopped early: \(sent) of \(data.count) bytes sent"
                : "-- image stream sent \(sent) of \(data.count) bytes")
            return sent
        } catch {
            log("!! image stream failed: \(error)")
            throw error
        }
    }

    public func disconnect() async {
        log("-- disconnect")
        await link.disconnect()
    }

    // MARK: annotations

    /// What `data` means, if it is a message the protocol knows: `outgoing` for commands
    /// written to the calendar, otherwise a notification from `characteristic`.
    public static func annotation(_ data: Data, on characteristic: GattCharacteristic, outgoing: Bool) -> String? {
        guard let opcode = data.first else { return nil }
        let bytes = [UInt8](data)
        if outgoing {
            switch opcode {
            case Opcode.imageHeader where bytes.count == 13:
                let length = bytes[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                let crc32 = bytes[7..<11].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                let crc16 = bytes[11..<13].reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
                return "image header: page \(bytes[5]), mode \(bytes[6]), \(length) bytes, "
                    + "crc32 \(padded(crc32, 8)), crc16 \(padded(crc16, 4))"
            case Opcode.unlock: return "unlock"
            case Opcode.battery: return "battery query"
            case Opcode.deviceInfo: return "device info query"
            case Opcode.getSlot: return "status query"
            case Opcode.disconnect: return "goodbye"
            case Opcode.showSlot where bytes.count == 2: return "show page \(bytes[1])"
            default: return nil
            }
        }
        switch (characteristic, data) {
        case (.command, Reply.headerOK): return "go: send the image"
        case (.command, Reply.headerBusy): return "busy"
        case (.command, Reply.headerSameImage): return "the page already holds this image"
        case (.command, Reply.unlockOK): return "unlocked"
        case (.command, Reply.deviceReady): return "device ready"
        case (.command, Reply.showSlotOK): return "page switched"
        case (.command, Data([Opcode.disconnect, 0x00])): return "goodbye ok"
        case (.image, Reply.dataOK): return "image received"
        case (.image, Reply.dataFail): return "image failed"
        default: break
        }
        guard characteristic == .command else { return nil }
        switch opcode {
        case Opcode.unlock:
            return "unlock rejected"
        case Opcode.battery:
            guard let battery = try? Messages.parseBattery(data) else { return nil }
            return battery.level.map { "battery \($0)/5" } ?? "charging"
        case Opcode.deviceInfo:
            return (try? Messages.parseDeviceInfo(data)).map { _ in "device info" }
        case Opcode.getSlot:
            guard let slot = try? Messages.parseSlot(data) else { return nil }
            return "page \(slot.page) on screen, crc32 \(padded(slot.crc32, 8))"
        default:
            return nil
        }
    }

    private static func line(_ arrow: String, _ characteristic: GattCharacteristic, _ data: Data,
                             outgoing: Bool) -> String {
        let name = characteristic == .command ? "command" : "image"
        let line = "\(arrow) \(name) \(data.hexString(separator: " "))"
        guard let note = annotation(data, on: characteristic, outgoing: outgoing) else { return line }
        return "\(line)  (\(note))"
    }

    /// Lower-case hex with leading zeros, e.g. `padded(0xBEEF, 8)` == "0000beef".
    private static func padded<T: BinaryInteger>(_ value: T, _ digits: Int) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: max(0, digits - hex.count)) + hex
    }

    private static func name(_ characteristic: ReadableCharacteristic) -> String {
        switch characteristic {
        case .modelNumber: "model number"
        case .firmwareRevision: "firmware revision"
        }
    }
}
