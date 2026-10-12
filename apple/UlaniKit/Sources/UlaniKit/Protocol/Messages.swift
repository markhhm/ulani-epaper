import Foundation

/// Battery state (`06 LL`).
public struct Battery: Sendable, Equatable {
    /// 0 (lowest) ... 5 (full); nil while charging.
    public let level: Int?
    public let charging: Bool

    public init(level: Int?, charging: Bool) {
        self.level = level
        self.charging = charging
    }
}

/// Device info (`0A` + MAC(6) + ASCII serial).
public struct DeviceInfo: Sendable, Equatable {
    /// Upper-case, colon separated, e.g. "11:22:33:44:55:66".
    public let mac: String
    public let serial: String

    public init(mac: String, serial: String) {
        self.mac = mac
        self.serial = serial
    }
}

/// Builders and parsers for the variable messages, as in protocol.py; argument
/// errors throw UlaniError.protocolError instead of trapping.
public enum Messages {
    /// 13-byte header announcing an image upload:
    /// `01 | len (u32 BE) | slot | mode | crc32 (BE) | crc16 (BE)`.
    public static func imageHeader(frameBytes: Data, page: Int,
                                   mode: Int = Int(Panel.defaultMode)) throws -> Data {
        guard (0...0xFF).contains(page) else {
            throw UlaniError.protocolError("slot must fit in one byte, got \(page)")
        }
        guard (0...0xFF).contains(mode) else {
            throw UlaniError.protocolError("mode must fit in one byte, got \(mode)")
        }
        guard let length = UInt32(exactly: frameBytes.count) else {
            throw UlaniError.protocolError("image too long: \(frameBytes.count) bytes")
        }
        var header = Data([Opcode.imageHeader])
        header.appendBigEndian(length)
        header.append(UInt8(page))
        header.append(UInt8(mode))
        header.appendBigEndian(Checksums.crc32(frameBytes))
        header.appendBigEndian(Checksums.crc16(frameBytes))
        return header
    }

    /// Command that makes the panel display `page` (like pressing the button).
    public static func showSlot(page: Int) throws -> Data {
        guard Panel.userSlots.contains(page) else {
            throw UlaniError.protocolError("slot must be 1-4, got \(page)")
        }
        return Data([Opcode.showSlot, UInt8(page)])
    }

    public static func parseBattery(_ data: Data) throws -> Battery {
        let b = try expect(Opcode.battery, data, minCount: 2)
        if b[1] == Reply.batteryCharging {
            return Battery(level: nil, charging: true)
        }
        return Battery(level: Int(b[1]), charging: false)
    }

    /// The page currently shown and the CRC32 of its image (`0C SS crc32`).
    public static func parseSlot(_ data: Data) throws -> (page: Int, crc32: UInt32) {
        let b = try expect(Opcode.getSlot, data, minCount: 6)
        let crc = b[2..<6].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (Int(b[1]), crc)
    }

    public static func parseDeviceInfo(_ data: Data) throws -> DeviceInfo {
        let b = try expect(Opcode.deviceInfo, data, minCount: 7)
        let mac = b[1..<7].map { byte in
            let s = String(byte, radix: 16, uppercase: true)
            return byte < 0x10 ? "0" + s : s
        }.joined(separator: ":")
        // Like Python's decode("ascii", errors="replace"): U+FFFD for each non-ASCII byte.
        let serial = String(String.UnicodeScalarView(b[7...].map {
            $0 < 0x80 ? Unicode.Scalar($0) : "\u{FFFD}"
        }))
        return DeviceInfo(mac: mac, serial: serial)
    }

    /// `data` split into pieces of `size` bytes (the last may be shorter). Each piece is
    /// its own Data (indices start at 0). Any positive size works, also for a slice
    /// (no `start + size`, which could overflow).
    public static func chunks(_ data: Data, size: Int) throws -> [Data] {
        guard size > 0 else { throw UlaniError.protocolError("chunk size must be positive") }
        var pieces: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = start + min(size, data.endIndex - start)
            pieces.append(Data(data[start..<end]))
            start = end
        }
        return pieces
    }

    /// The bytes of `data` if it starts with `opcode` and has at least `minCount` bytes.
    private static func expect(_ opcode: UInt8, _ data: Data, minCount: Int) throws -> [UInt8] {
        let bytes = [UInt8](data)
        guard bytes.count >= minCount, bytes.first == opcode else {
            throw UlaniError.protocolError(
                "expected opcode 0x\(Data([opcode]).hexString()), got \(data.hexString(separator: " "))")
        }
        return bytes
    }
}

extension Data {
    /// Lower-case hex, e.g. `hexString(separator: " ")` == "0c 00".
    func hexString(separator: String = "") -> String {
        map { byte in
            let s = String(byte, radix: 16)
            return byte < 0x10 ? "0" + s : s
        }.joined(separator: separator)
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
