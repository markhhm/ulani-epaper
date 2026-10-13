import Compression
import Foundation
import UlaniKit

/// The zip a `.paperhue-card` file is (shared/CARDS.md), and no more of the format than that:
/// entries stored or deflated (raw DEFLATE, Foundation's `.zlib`), found by name in the central
/// directory; no encryption, no ZIP64. Entry names are only compared, never used as paths.
/// Reading throws `CardError.damagedFile`, `.missingEntry` and `.entryTooBig`.
struct CardZip {
    private struct Entry {
        let flags: Int, method: Int, crc: Int, compressedSize: Int, size: Int, offset: Int
    }

    private let data: Data
    /// By name; of two with the same name the later one, as Python's zipfile has it.
    private let entries: [String: Entry]

    /// Reads the central directory of `data` (which may be memory-mapped: entries are read
    /// only when asked for).
    init(_ data: Data) throws {
        self.data = data
        // the end of central directory record: 22 bytes, then a comment of at most 65535
        guard let end = stride(from: data.count - 22, through: max(0, data.count - 22 - 0xFFFF), by: -1)
            .first(where: { Self.u32(data, $0) == 0x0605_4B50 }) else {
            throw CardError.damagedFile("not a zip file")
        }
        var entries: [String: Entry] = [:]
        var at = Self.u32(data, end + 16)
        for _ in 0..<Self.u16(data, end + 10) {
            guard at + 46 <= data.count, Self.u32(data, at) == 0x0201_4B50 else {
                throw CardError.damagedFile("bad central directory")
            }
            let nameLength = Self.u16(data, at + 28)
            guard at + 46 + nameLength <= data.count else { throw CardError.damagedFile("bad central directory") }
            let name = String(decoding: data[(data.startIndex + at + 46)..<(data.startIndex + at + 46 + nameLength)],
                              as: UTF8.self)
            entries[name] = Entry(flags: Self.u16(data, at + 8), method: Self.u16(data, at + 10),
                                  crc: Self.u32(data, at + 16), compressedSize: Self.u32(data, at + 20),
                                  size: Self.u32(data, at + 24), offset: Self.u32(data, at + 42))
            at += 46 + nameLength + Self.u16(data, at + 30) + Self.u16(data, at + 32)
        }
        self.entries = entries
    }

    /// The contents of entry `name`, refused when it is bigger than `limit` (before reading).
    func read(_ name: String, limit: Int) throws -> Data {
        guard let e = entries[name] else { throw CardError.missingEntry(name) }
        if e.size > limit { throw CardError.entryTooBig(name) }
        if e.flags & 1 != 0 { throw CardError.damagedFile("\(name) is encrypted") }
        guard e.offset + 30 <= data.count, Self.u32(data, e.offset) == 0x0403_4B50 else {
            throw CardError.damagedFile("bad local header of \(name)")
        }
        let start = e.offset + 30 + Self.u16(data, e.offset + 26) + Self.u16(data, e.offset + 28)
        guard start + e.compressedSize <= data.count else { throw CardError.damagedFile("\(name) is cut short") }
        let raw = (data.startIndex + start)..<(data.startIndex + start + e.compressedSize)
        let contents: Data? = switch e.method {
        case 0: e.compressedSize == e.size ? data[raw] : nil
        case 8: Self.inflate(data, raw, size: e.size)
        default: throw CardError.damagedFile("\(name) uses compression method \(e.method)")
        }
        guard let contents, Int(Checksums.crc32(contents)) == e.crc else {
            throw CardError.damagedFile("\(name) is damaged")
        }
        return Data(contents)
    }

    /// A zip of `entries` in order, `deflate`d or stored, dated 1980-01-01.
    static func write(_ entries: [(name: String, data: Data, deflate: Bool)]) throws -> Data {
        var out = Data(), directory = Data()
        for e in entries {
            let body = e.deflate ? try (e.data as NSData).compressed(using: .zlib) as Data : e.data
            let name = Data(e.name.utf8)
            // version needed, flags, method, time, date, CRC-32, sizes, name length, extra length
            let fields = le(20, 2) + le(0, 2) + le(e.deflate ? 8 : 0, 2) + le(0, 2) + le(0x21, 2)
                + le(Int(Checksums.crc32(e.data)), 4) + le(body.count, 4) + le(e.data.count, 4) + le(name.count, 2) + le(0, 2)
            // ... then (central directory only) comment length, disk, attributes, local header offset
            directory += le(0x0201_4B50, 4) + le(20, 2) + fields + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4)
                + le(out.count, 4) + name
            out += le(0x0403_4B50, 4) + fields + name + body
        }
        let start = out.count
        return out + directory + le(0x0605_4B50, 4) + le(0, 2) + le(0, 2) + le(entries.count, 2) + le(entries.count, 2)
            + le(directory.count, 4) + le(start, 4) + le(0, 2)
    }

    // MARK: -

    /// Raw DEFLATE data, if it inflates to exactly `size` bytes (into a buffer one byte larger,
    /// so a stream that says less than it holds is caught and never fills memory).
    private static func inflate(_ data: Data, _ range: Range<Data.Index>, size: Int) -> Data? {
        guard !range.isEmpty else { return nil }
        var out = Data(count: size + 1)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                                          src.bindMemory(to: UInt8.self).baseAddress! + (range.lowerBound - data.startIndex),
                                          range.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out.prefix(size) : nil
    }

    /// Little-endian unsigned integers at byte `i`; 0 past the end.
    private static func u16(_ data: Data, _ i: Int) -> Int {
        guard i >= 0, i + 2 <= data.count else { return 0 }
        return Int(data[data.startIndex + i]) | Int(data[data.startIndex + i + 1]) << 8
    }

    private static func u32(_ data: Data, _ i: Int) -> Int {
        guard i >= 0, i + 4 <= data.count else { return 0 }
        return u16(data, i) | u16(data, i + 2) << 16
    }
}

/// `value` as `count` little-endian bytes.
private func le(_ value: Int, _ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
}
