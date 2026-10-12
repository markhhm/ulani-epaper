import Foundation

/// The bundled Noto Sans CJK TC subsets (SIL Open Font License, Fonts/OFL.txt): which
/// characters they draw, and the cleaning every drawn string goes through
/// (python/src/ulani_epaper/fonts/__init__.py). The subsets keep only the Traditional Chinese
/// glyph forms, so Simplified Chinese, kana and Hangul draw the same whatever language
/// CoreText assumes.
public enum PageFonts {
    /// The OTF file of one weight in `PaperhuePages.fontsDirectory` (Python: `fonts.path`).
    public static func url(bold: Bool) -> URL {
        PaperhuePages.fontsDirectory.appendingPathComponent("NotoSansCJKtc-\(bold ? "Bold" : "Regular")-subset.otf")
    }

    /// Every code point the bundled fonts map to a glyph, from the regular file's cmap (both
    /// weights are subset to the same set; Python: `fonts.codepoints()`).
    public static var codepoints: Set<UInt32> { coverage }

    private static let coverage = Set(PageFace.regular.file.glyphs.keys)

    /// True if the pages can draw `scalar`: the font maps it, and it is not an invisible format
    /// character (general category Cf: zero-width joiners, the BOM, the soft hyphen) or a
    /// variation selector (Python: `fonts.has_glyph`).
    public static func hasGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xFE00...0xFE0F, 0xE0100...0xE01EF: return false
        default: break
        }
        return scalar.properties.generalCategory != .format && coverage.contains(scalar.value)
    }

    /// Text as the pages can draw it (Python: `fonts.clean`): composed (NFC, so a decomposed
    /// "Café" keeps its é), line breaks, tabs and other whitespace or control characters turned
    /// into spaces, emoji and every other character the font cannot draw dropped, runs of
    /// spaces folded into one, no space at either end.
    public static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var space = false  // a space is due before the next kept character
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if becomesSpace(scalar) {
                space = !out.isEmpty
            } else if hasGlyph(scalar) {
                if space { out.append(" ") }
                out.append(scalar)
                space = false
            }
        }
        return String(out)
    }

    /// What `clean` turns into a space: Python's `str.isspace()` and the control characters (Cc).
    static func becomesSpace(_ scalar: Unicode.Scalar) -> Bool {
        PythonText.isSpace(scalar) || scalar.properties.generalCategory == .control
    }
}
