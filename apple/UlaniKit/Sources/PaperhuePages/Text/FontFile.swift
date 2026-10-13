import Foundation

/// A bundled font file that cannot be read (it is checked byte for byte against the Python
/// reference's, so this means a broken build).
struct FontFileError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// What the text rules read from an OTF's tables: the character map (as in
/// python/src/ulani_epaper/fonts/__init__.py `_cmap`) and the advance widths (`hmtx`, which is
/// what FreeType measures a CFF-based OpenType font with).
struct FontFile: Sendable {
    /// Font units per em (`head`).
    let unitsPerEm: Int
    /// Code point -> glyph id, for the code points mapped to a glyph other than 0 (the font's
    /// coverage, as `_cmap` returns it).
    let glyphs: [UInt32: UInt32]
    /// Advance width in font units for each glyph id (glyphs past `hhea.numberOfHMetrics`
    /// repeat the last width).
    let advances: [UInt16]

    init(data: Data) throws {
        let bytes = [UInt8](data)
        let tables = try Self.tables(bytes)
        func table(_ tag: String) throws -> BigEndian {
            guard let range = tables[tag], range.upperBound <= bytes.count else {
                throw FontFileError("font has no \(tag) table")
            }
            return BigEndian(bytes: bytes, range: range)
        }
        unitsPerEm = Int(try table("head").u16(18))
        let numberOfHMetrics = Int(try table("hhea").u16(34))
        let numGlyphs = Int(try table("maxp").u16(4))
        let hmtx = try table("hmtx")
        guard numberOfHMetrics > 0, unitsPerEm > 0 else { throw FontFileError("font has no horizontal metrics") }
        var advances = try (0..<numberOfHMetrics).map { try hmtx.u16(4 * $0) }
        advances += Array(repeating: advances[numberOfHMetrics - 1], count: max(0, numGlyphs - numberOfHMetrics))
        self.advances = advances
        glyphs = try Self.characterMap(table("cmap"))
    }

    /// The glyph FreeType draws for `codePoint`: 0 (.notdef) when the font lacks it.
    func glyph(for codePoint: UInt32) -> Int {
        let glyph = Int(glyphs[codePoint] ?? 0)
        return glyph < advances.count ? glyph : 0
    }

    /// The table directory: tag -> byte range.
    private static func tables(_ bytes: [UInt8]) throws -> [String: Range<Int>] {
        let file = BigEndian(bytes: bytes, range: 0..<bytes.count)
        var tables: [String: Range<Int>] = [:]
        for i in 0..<Int(try file.u16(4)) {
            let record = 12 + 16 * i
            let tag = String(decoding: try file.slice(record, 4), as: UTF8.self)
            let offset = Int(try file.u32(record + 8)), length = Int(try file.u32(record + 12))
            tables[tag] = offset..<offset + length
        }
        return tables
    }

    /// The first Unicode subtable of format 12 or 4, preferring (3, 10), (0, 4), (3, 1), (0, 3),
    /// exactly as `_cmap` reads it.
    private static func characterMap(_ cmap: BigEndian) throws -> [UInt32: UInt32] {
        var subtables: [Int: Int] = [:]  // platform << 16 | encoding -> offset
        for i in 0..<Int(try cmap.u16(2)) {
            let platform = Int(try cmap.u16(4 + 8 * i)), encoding = Int(try cmap.u16(6 + 8 * i))
            subtables[platform << 16 | encoding] = Int(try cmap.u32(8 + 8 * i))
        }
        for key in [3 << 16 | 10, 0 << 16 | 4, 3 << 16 | 1, 0 << 16 | 3] {
            guard let offset = subtables[key] else { continue }
            switch try cmap.u16(offset) {
            case 12: return try format12(cmap, offset)
            case 4: return try format4(cmap, offset)
            default: continue
            }
        }
        throw FontFileError("font has no Unicode cmap subtable of format 4 or 12")
    }

    private static func format12(_ cmap: BigEndian, _ offset: Int) throws -> [UInt32: UInt32] {
        var map: [UInt32: UInt32] = [:]
        for g in 0..<Int(try cmap.u32(offset + 12)) {
            let group = offset + 16 + 12 * g
            let start = try cmap.u32(group), end = try cmap.u32(group + 4), first = try cmap.u32(group + 8)
            guard start <= end else { continue }
            for c in start...end {
                let glyph = first &+ (c - start)
                if glyph != 0 { map[c] = glyph }
            }
        }
        return map
    }

    private static func format4(_ cmap: BigEndian, _ offset: Int) throws -> [UInt32: UInt32] {
        let segments = Int(try cmap.u16(offset + 6)) / 2
        let ends = offset + 14, starts = offset + 16 + 2 * segments
        let deltas = starts + 2 * segments, rangeOffsets = deltas + 2 * segments
        var map: [UInt32: UInt32] = [:]
        for s in 0..<segments {
            let start = Int(try cmap.u16(starts + 2 * s)), end = Int(try cmap.u16(ends + 2 * s))
            let delta = Int(try cmap.u16(deltas + 2 * s))  // idDelta works modulo 65536
            let rangeOffsetAt = rangeOffsets + 2 * s
            let rangeOffset = Int(try cmap.u16(rangeOffsetAt))
            guard start <= end else { continue }
            for c in start...end where c != 0xFFFF {
                var glyph: Int
                if rangeOffset == 0 {
                    glyph = (c + delta) & 0xFFFF
                } else {
                    glyph = Int(try cmap.u16(rangeOffsetAt + rangeOffset + 2 * (c - start)))
                    if glyph != 0 { glyph = (glyph + delta) & 0xFFFF }
                }
                if glyph != 0 { map[UInt32(c)] = UInt32(glyph) }
            }
        }
        return map
    }
}

/// Big-endian reads inside one table; reading past its end throws.
private struct BigEndian {
    let bytes: [UInt8]
    let range: Range<Int>

    func slice(_ at: Int, _ count: Int) throws -> ArraySlice<UInt8> {
        guard at >= 0, count >= 0, at + count <= range.count else {
            throw FontFileError("font table ends before byte \(at + count)")
        }
        return bytes[range.lowerBound + at..<range.lowerBound + at + count]
    }

    func u16(_ at: Int) throws -> UInt16 {
        try slice(at, 2).reduce(0) { $0 << 8 | UInt16($1) }
    }

    func u32(_ at: Int) throws -> UInt32 {
        try slice(at, 4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}
