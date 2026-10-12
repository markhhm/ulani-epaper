import Foundation
import Testing
@testable import PaperhuePages

// The expectations computed with the Python reference (Differential/make_text_expectations.py,
// Pillow's FreeType measuring the bundled fonts). Cases are JSON arrays, decoded by position.

/// Differential/text-expectations.json.
struct TextExpectations: Decodable, Sendable {
    /// Pillow's getlength(text) at `size`.
    struct Length: Decodable, Sendable {
        let text: String
        let font: PageFont
        let length: Int

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            text = try c.decode(String.self)
            font = try PageFont(size: c.decode(Int.self), bold: c.decode(Int.self) != 0)
            length = try c.decode(Int.self)
        }
    }

    /// One call of the pages' text primitive (`layouts._Page.text`) while the reference drew the
    /// shared fixtures: what it was given, what it drew ("" for nothing) and the width it returned.
    struct PageTextCall: Decodable, Sendable {
        let input: String
        let font: PageFont
        let maxWidth: Double?
        let drawn: String
        let width: Int

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            input = try c.decode(String.self)
            font = try PageFont(size: c.decode(Int.self), bold: c.decode(Int.self) != 0)
            maxWidth = try c.decodeNil() ? nil : c.decode(Double.self)
            drawn = try c.decode(String.self)
            width = try c.decode(Int.self)
        }
    }

    /// The covered code points in order, `glyph_chunk` at a time: each chunk's length.
    struct GlyphSums: Decodable, Sendable {
        let font: PageFont
        let lengths: [Int]

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            font = try PageFont(size: c.decode(Int.self), bold: c.decode(Int.self) != 0)
            lengths = try c.decode([Int].self)
        }
    }

    /// One character per advance width; `lengths[size - 8][i]` is character i at `size`.
    struct OtherSizes: Decodable, Sendable {
        let text: String
        let bold: Bool
        let lengths: [[Int]]

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            text = try c.decode(String.self)
            bold = try c.decode(Int.self) != 0
            lengths = try c.decode([[Int]].self)
        }
    }

    /// getbbox(character, anchor="ls"): left, top, right, bottom.
    struct Extent: Decodable, Sendable {
        let character: Unicode.Scalar
        let font: PageFont
        let box: [Int]

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let text = try c.decode(String.self)
            guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not one character: \(text)")
            }
            character = scalar
            font = try PageFont(size: c.decode(Int.self), bold: c.decode(Int.self) != 0)
            box = try c.decode([Int].self)
        }
    }

    /// layouts._fit(text, font, width) for several widths.
    struct Fit: Decodable, Sendable {
        let text: String
        let font: PageFont
        let results: [(width: Double, text: String)]

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            text = try c.decode(String.self)
            font = try PageFont(size: c.decode(Int.self), bold: c.decode(Int.self) != 0)
            var results: [(width: Double, text: String)] = []
            var list = try c.nestedUnkeyedContainer()
            while !list.isAtEnd {
                var pair = try list.nestedUnkeyedContainer()
                results.append(try (pair.decode(Double.self), pair.decode(String.self)))
            }
            self.results = results
        }
    }

    /// layouts._wrap(text, font, width, max_lines).
    struct Wrap: Decodable, Sendable {
        let text: String
        let font: PageFont
        let width: Double
        let maxLines: Int
        let lines: [String]

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            text = try c.decode(String.self)
            font = try PageFont(size: c.decode(Int.self), bold: c.decode(Int.self) != 0)
            width = try c.decode(Double.self)
            maxLines = try c.decode(Int.self)
            lines = try c.decode([String].self)
        }
    }

    /// An input (null for None) and what the function returns for it.
    struct Pair: Decodable, Sendable {
        let input: String?
        let output: String

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            input = try c.decodeNil() ? nil : c.decode(String.self)
            output = try c.decode(String.self)
        }
    }

    /// Code points `first...last` that clean() turns into a space ("s") or keeps ("k").
    struct Run: Decodable, Sendable {
        let range: ClosedRange<UInt32>
        let kind: String

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            range = try c.decode(UInt32.self)...c.decode(UInt32.self)
            kind = try c.decode(String.self)
        }
    }

    struct Accents: Decodable, Sendable {
        /// "rrggbb" + the initial of accent("#rrggbb"), colour after colour.
        let table: String
        let inputs: [Input]

        /// [input, accent(input), accent(input, default="blue")]
        struct Input: Decodable, Sendable {
            let input: String?
            let accent: String
            let withBlueDefault: String

            init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                input = try c.decodeNil() ? nil : c.decode(String.self)
                accent = try c.decode(String.self)
                withBlueDefault = try c.decode(String.self)
            }
        }
    }

    let pillow: String
    let freetype: String
    let pageSizes: [Int]
    let glyphChunk: Int
    let lengths: [Length]
    let pageTexts: [PageTextCall]
    let glyphSums: [GlyphSums]
    let otherSizes: [OtherSizes]
    let extents: [Extent]
    let fit: [Fit]
    let wrap: [Wrap]
    let clean: [Pair]
    let titles: [Pair]
    let classes: [Run]
    let accent: Accents

    enum CodingKeys: String, CodingKey {
        case pillow, freetype, pageSizes = "page_sizes", glyphChunk = "glyph_chunk", lengths,
             pageTexts = "page_texts", glyphSums = "glyph_sums", otherSizes = "other_sizes", extents, fit, wrap, clean, titles,
             classes, accent
    }

    private static let loaded = Result<TextExpectations, any Error> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Differential/text-expectations.json")
        return try JSONDecoder().decode(TextExpectations.self, from: Data(contentsOf: url))
    }

    static func load() throws -> TextExpectations { try loaded.get() }
}

extension PageFont: CustomTestStringConvertible {
    public var testDescription: String { "\(size) px \(bold ? "bold" : "regular")" }
}
