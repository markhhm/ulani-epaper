import Foundation
import Testing
import UlaniKit
@testable import PaperhuePages

/// The fonts and text rules against the Python reference (Differential/text-expectations.json):
/// every width, cut, line and colour must be exactly what Pillow and layouts.py give.
@Suite struct TextDifferentialTests {
    @Test func lengthsMatchPillow() throws {
        let cases = try TextExpectations.load().lengths
        #expect(cases.count >= 600)
        for c in cases {
            #expect(c.font.length(c.text) == Double(c.length), "\(c.text) at \(c.font.testDescription)")
        }
    }

    /// The text primitive on the reference's own pages: every string cleaned and cut as the
    /// Python reference drew it, the same width returned, and no CJK below 18 px (LAYOUTS.md 1.1).
    @Test func pageTextsMatchTheReference() throws {
        let calls = try TextExpectations.load().pageTexts
        #expect(calls.count >= 300)
        #expect(calls.contains { $0.font.size < PageText.minimumCJKSize })
        #expect(calls.contains { $0.maxWidth != nil && $0.drawn != $0.input })
        for c in calls {
            let drawn = PageText.drawable(c.input, font: c.font, maxWidth: c.maxWidth)
            #expect(drawn == c.drawn, "\(c.input) at \(c.font.testDescription) in \(c.maxWidth.map(String.init(describing:)) ?? "any width")")
            #expect(c.font.length(drawn) == Double(c.width), "\(c.drawn) at \(c.font.testDescription)")
            #expect(PageText.mayDraw(drawn, size: c.font.size, bold: c.font.bold), "\(c.drawn) at \(c.font.testDescription)")
        }
    }

    @Test func everyGlyphAtEveryPageSizeMatchesPillow() throws {
        let expectations = try TextExpectations.load()
        let covered = PageFonts.codepoints.filter { PageFonts.hasGlyph(Unicode.Scalar($0)!) }.sorted()
        let chunks = stride(from: 0, to: covered.count, by: expectations.glyphChunk).map { start in
            String(String.UnicodeScalarView(
                covered[start..<min(start + expectations.glyphChunk, covered.count)].map { Unicode.Scalar($0)! }))
        }
        #expect(Set(expectations.glyphSums.map(\.font.size)) == Set(expectations.pageSizes))
        for sums in expectations.glyphSums {
            #expect(chunks.map { sums.font.length($0) } == sums.lengths.map(Double.init), "\(sums.font.testDescription)")
        }
    }

    @Test func everyAdvanceWidthAtSizesFrom8To140MatchesPillow() throws {
        for other in try TextExpectations.load().otherSizes {
            #expect(other.text.unicodeScalars.count > 100)
            for (i, size) in (8...140).enumerated() {
                let font = PageFont(size: size, bold: other.bold)
                #expect(other.text.unicodeScalars.map { font.advance($0) } == other.lengths[i], "\(font.testDescription)")
            }
        }
    }

    @Test func extentsMatchPillowsBoundingBoxes() throws {
        for e in try TextExpectations.load().extents {
            let extent = e.font.verticalExtent(of: e.character)
            #expect(extent.top == e.box[1] && extent.bottom == e.box[3], "\(e.character) at \(e.font.testDescription)")
        }
    }

    @Test func fitMatchesTheReference() throws {
        var count = 0
        for c in try TextExpectations.load().fit {
            for (width, expected) in c.results {
                #expect(PageText.fit(c.text, font: c.font, width: width) == expected,
                        "\(c.text) at \(c.font.testDescription) in \(width)")
                count += 1
            }
        }
        #expect(count >= 1000)
    }

    @Test func wrapMatchesTheReference() throws {
        let cases = try TextExpectations.load().wrap
        #expect(cases.count >= 500)
        for c in cases {
            #expect(PageText.wrap(c.text, font: c.font, width: c.width, maxLines: c.maxLines) == c.lines,
                    "\(c.text) at \(c.font.testDescription) in \(c.width), \(c.maxLines) lines")
        }
    }

    @Test func cleanMatchesTheReference() throws {
        for c in try TextExpectations.load().clean {
            #expect(PageFonts.clean(c.input ?? "") == c.output, "\(c.input.debugDescription)")
        }
    }

    @Test func titlesMatchTheReference() throws {
        for c in try TextExpectations.load().titles {
            #expect(PageText.title(c.input) == c.output, "\(c.input.debugDescription)")
        }
    }

    /// clean() character by character, over every code point: what becomes a space, what is kept
    /// (the cmap coverage, without format characters and variation selectors), what is dropped.
    @Test func everyCodePointIsClassifiedAsTheReferenceDoes() throws {
        var expected = [UInt8](repeating: 0, count: 0x110000)  // 0 dropped, 1 kept, 2 space
        for run in try TextExpectations.load().classes {
            for c in run.range { expected[Int(c)] = run.kind == "s" ? 2 : 1 }
        }
        var wrong: [String] = []
        for value in UInt32(0)..<0x110000 {
            guard let scalar = Unicode.Scalar(value) else { continue }  // surrogates
            let actual: UInt8 = PageFonts.becomesSpace(scalar) ? 2 : PageFonts.hasGlyph(scalar) ? 1 : 0
            if actual != expected[Int(value)] { wrong.append(String(format: "U+%04X", value)) }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(20))")
    }

    @Test func accentMatchesTheReference() throws {
        let accents = try TextExpectations.load().accent
        let initials: [Character: PanelColour] = ["k": .black, "r": .red, "o": .orange, "y": .yellow, "g": .green, "b": .blue]
        let table = Array(accents.table)
        #expect(table.count == 7 * (16 * 16 * 16 + 6000))
        var wrong: [String] = []
        for i in stride(from: 0, to: table.count, by: 7) {
            let hex = String(table[i..<i + 6])
            if PanelColour.accent("#" + hex) != initials[table[i + 6]] { wrong.append(hex) }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(20))")
        for c in accents.inputs {
            #expect(PanelColour.accent(c.input).rawValue == c.accent, "\(c.input.debugDescription)")
            #expect(PanelColour.accent(c.input, default: .blue).rawValue == c.withBlueDefault, "\(c.input.debugDescription)")
        }
    }
}
