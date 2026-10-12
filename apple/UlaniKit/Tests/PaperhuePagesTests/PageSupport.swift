import Foundation
import ImageIO
import PaperhueAgenda
import Testing
@testable import PaperhuePages

// The drawing expectations computed with the Python reference
// (Differential/make_page_expectations.py), the golden renders in shared/layouts/agenda/golden/
// (read straight from the repo), and the pixel comparison of a page with its golden render.

enum PageRepo {
    /// The repository root (this file is apple/UlaniKit/Tests/PaperhuePagesTests/PageSupport.swift).
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let agendaFixtures = root.appendingPathComponent("shared/layouts/agenda")
    static let agendaGoldens = agendaFixtures.appendingPathComponent("golden")

    static func fixture(_ name: String) throws -> AgendaFixture {
        try AgendaFixture(contentsOf: agendaFixtures.appendingPathComponent("\(name).json"))
    }

    /// "+08:00" (a fixed offset) or an IANA name.
    static func zone(_ name: String) throws -> TimeZone {
        if name.first == "+" || name.first == "-" {
            let parts = name.dropFirst().split(separator: ":").compactMap { Int($0) }
            let seconds = (parts[0] * 3600 + parts[1] * 60) * (name.first == "-" ? -1 : 1)
            return try #require(TimeZone(secondsFromGMT: seconds))
        }
        return try #require(TimeZone(identifier: name))
    }
}

/// Differential/page-expectations.json.
struct PageExpectations: @unchecked Sendable {
    /// One drawing call alone on a white page: the call, the region read back, the hash of its runs.
    struct Shape {
        let call: [Any]
        let region: (x0: Int, y0: Int, x1: Int, y1: Int)
        let hash: String

        var description: String { call.map { "\($0)" }.joined(separator: " ") }
    }

    /// One render_month call and the drawing calls it made.
    struct Month: Sendable {
        let name: String
        /// A fixture name, or AgendaData JSON.
        let data: String
        let today: String
        let zone: String
        let operations: [String]

        func agenda() throws -> AgendaData {
            data.hasPrefix("{") ? try AgendaData.fromJSON(Data(data.utf8)) : try PageRepo.fixture(data).data
        }
    }

    let shapes: [Shape]
    let months: [Month]

    private static let loaded = Result<PageExpectations, any Error> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Differential/page-expectations.json")
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let shapes = try #require(raw["shapes"] as? [[Any]]).map { item in
            let region = item[item.count - 2] as! [Int]
            return Shape(call: Array(item.dropLast(2)), region: (region[0], region[1], region[2], region[3]),
                         hash: item[item.count - 1] as! String)
        }
        let months = try #require(raw["months"] as? [[String: Any]]).map { m in
            Month(name: m["name"] as! String, data: m["data"] as! String, today: m["today"] as! String,
                  zone: m["zone"] as! String, operations: m["ops"] as! [String])
        }
        return PageExpectations(shapes: shapes, months: months)
    }

    static func load() throws -> PageExpectations { try loaded.get() }
}

extension PageCanvas {
    /// The region's non-white runs, row by row, as "y,x0,x1,c" joined by spaces (c the colour's
    /// initial, k for black), as make_page_expectations.py writes them before hashing.
    func runs(_ region: (x0: Int, y0: Int, x1: Int, y1: Int)) -> String {
        var out: [String] = []
        for y in region.y0...region.y1 {
            var x = region.x0
            while x <= region.x1 {
                let c = self[x: x, y: y]
                if c == .white {
                    x += 1
                    continue
                }
                let start = x
                while x + 1 <= region.x1 && self[x: x + 1, y: y] == c { x += 1 }
                out.append("\(y),\(start),\(x),\(c == .black ? "k" : String(c.rawValue.prefix(1)))")
                x += 1
            }
        }
        return out.joined(separator: " ")
    }
}

/// FNV-1a, 64 bits, of the UTF-8 bytes, as 16 hex digits.
func fnv1a(_ text: String) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    let hex = String(h, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
}

/// A golden PNG as panel colours, row-major (nil where a pixel is not one of the 7).
func goldenPixels(_ url: URL) throws -> [PanelColour?] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    try #require(image.width == PageCanvas.width && image.height == PageCanvas.height && image.bitsPerComponent == 8)
    let channels = image.bitsPerPixel / 8
    try #require(channels == 3 || channels == 4)
    let data = try #require(image.dataProvider?.data as Data?)  // the stored samples, no colour conversion
    var byRGB: [UInt32: PanelColour] = [:]
    for colour in PanelColour.allCases {
        byRGB[UInt32(colour.rgb.r) << 16 | UInt32(colour.rgb.g) << 8 | UInt32(colour.rgb.b)] = colour
    }
    return data.withUnsafeBytes { bytes in
        var out: [PanelColour?] = []
        out.reserveCapacity(PageCanvas.width * PageCanvas.height)
        for y in 0..<PageCanvas.height {
            for x in 0..<PageCanvas.width {
                let o = y * image.bytesPerRow + x * channels
                out.append(byRGB[UInt32(bytes[o]) << 16 | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2])])
            }
        }
        return out
    }
}

/// How a page differs from its golden render.
///
/// Outside the strings' boxes (each string's bounds plus `GlyphRaster.margin`) every pixel
/// must be the golden's. Inside a box, a pixel may differ only between the string's colour and
/// what lies under the text (the same page drawn without glyphs): a glyph pixel one rasteriser
/// set and the other did not. Any other difference is an error.
struct GoldenComparison {
    /// One drawn string: its glyph pixels here and in the golden.
    struct Run {
        let text: String
        /// Glyph pixels here, in the golden, and in exactly one of the two.
        var ink = 0, goldenInk = 0, different = 0
        /// Glyph pixels (of either) with no glyph pixel of the other within 1 px (the pixel or
        /// its 8 neighbours), and within 3 px (the 7 x 7 square around it).
        var farther1 = 0, farther3 = 0
    }

    /// Pixels that differ outside every text box, or inside one by a colour no glyph explains.
    var errors: [(x: Int, y: Int)] = []
    var runs: [Run] = []
    /// Pixels that differ in all.
    var differentPixels = 0

    init(page: PageCanvas, bare: PageCanvas, golden: [PanelColour?]) {
        let w = PageCanvas.width, h = PageCanvas.height
        var allowed = [Set<PanelColour>?](repeating: nil, count: w * h)
        for run in page.textRuns {
            for y in max(run.box.y0, 0)...min(run.box.y1, h - 1) {
                for x in max(run.box.x0, 0)...min(run.box.x1, w - 1) {
                    let i = y * w + x
                    allowed[i] = (allowed[i] ?? [bare.pixels[i]]).union([run.fill])
                }
            }
        }
        for i in 0..<page.pixels.count where page.pixels[i] != golden[i] {
            differentPixels += 1
            guard let ok = allowed[i], let g = golden[i], ok.contains(page.pixels[i]), ok.contains(g) else {
                errors.append((i % w, i / w))
                continue
            }
        }
        for textRun in page.textRuns {
            let box = textRun.box
            // a glyph pixel: the string's colour where the page without glyphs has another
            func ink(_ pixels: (Int) -> PanelColour?, _ x: Int, _ y: Int) -> Bool {
                guard x >= max(box.x0, 0), x <= min(box.x1, w - 1), y >= max(box.y0, 0), y <= min(box.y1, h - 1)
                else { return false }
                let i = y * w + x
                return bare.pixels[i] != textRun.fill && pixels(i) == textRun.fill
            }
            let here = { (i: Int) -> PanelColour? in page.pixels[i] }, there = { (i: Int) in golden[i] }
            func near(_ pixels: (Int) -> PanelColour?, _ x: Int, _ y: Int, _ d: Int) -> Bool {
                (y - d...y + d).contains { yy in (x - d...x + d).contains { xx in ink(pixels, xx, yy) } }
            }
            var run = Run(text: textRun.text)
            for y in max(box.y0, 0)...min(box.y1, h - 1) {
                for x in max(box.x0, 0)...min(box.x1, w - 1) {
                    let a = ink(here, x, y), b = ink(there, x, y)
                    if a { run.ink += 1 }
                    if b { run.goldenInk += 1 }
                    if a != b { run.different += 1 }
                    if (a && !near(there, x, y, 1)) || (b && !near(here, x, y, 1)) { run.farther1 += 1 }
                    if (a && !near(there, x, y, 3)) || (b && !near(here, x, y, 3)) { run.farther3 += 1 }
                }
            }
            runs.append(run)
        }
    }
}
