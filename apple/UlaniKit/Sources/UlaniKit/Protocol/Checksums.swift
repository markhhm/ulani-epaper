import Foundation

/// Checksums of the image header (both big-endian on the wire).
public enum Checksums {
    /// CRC-16/XMODEM (poly 0x1021, init 0), bitwise like protocol.crc16.
    public static func crc16(_ data: Data) -> UInt16 {
        data.withUnsafeBytes { bytes in
            var crc: UInt16 = 0
            for byte in bytes {
                crc ^= UInt16(byte) << 8
                for _ in 0..<8 {
                    crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
                }
            }
            return crc
        }
    }

    /// CRC-32 (IEEE 802.3, as zlib.crc32): reflected poly 0xEDB88320, init/xorout 0xFFFFFFFF.
    public static func crc32(_ data: Data) -> UInt32 {
        crc32Table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { bytes in
                var crc: UInt32 = 0xFFFF_FFFF
                for byte in bytes {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
                return crc ^ 0xFFFF_FFFF
            }
        }
    }

    private static let crc32Table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }
}
