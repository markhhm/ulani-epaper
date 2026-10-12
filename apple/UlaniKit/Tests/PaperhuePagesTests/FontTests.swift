import CoreText
import Foundation
import Testing
@testable import PaperhuePages

/// CoreText's glyph for each character of `text` in `font` (0 = .notdef, the font lacks it).
private func coreTextGlyphs(_ text: String, _ font: CTFont) -> [CGGlyph] {
    text.unicodeScalars.map { scalar in
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        return glyphs[0]
    }
}

/// python/tests/test_fonts.py, plus what the Swift side adds: CoreText draws the glyphs the
/// widths are measured from.
@Suite struct FontTests {
    @Test(arguments: [false, true])
    func bundledFontLoads(bold: Bool) {
        let font = PageFont(size: 24, bold: bold)
        #expect(font.length("永恆曆") == 72)
        let name = CTFontCopyPostScriptName(font.ctFont) as String
        #expect(name == (bold ? "NotoSansCJKtc-Bold" : "NotoSansCJKtc-Regular"))
        #expect(CTFontGetSize(font.ctFont) == 24)
    }

    @Test(arguments: [false, true])
    func bundledFontCoversWhatThePagesDraw(bold: Bool) {
        let needed = "永恆曆龘行事曆待辦今天明天還有項週一二三四五六日0123456789:–…○●✓→ABCxyz"
        let ctFont = PageFont(size: 24, bold: bold).ctFont
        #expect(needed.unicodeScalars.filter { !PageFonts.hasGlyph($0) } == [])
        #expect(coreTextGlyphs(needed, ctFont).filter { $0 == 0 } == [])
    }

    @Test(arguments: [false, true], [
        "们这简为发说时间会议国际",  // Simplified Chinese (GB2312)
        "ひらがなカタカナ",  // Japanese kana
        "ミーティング・カレンダー",  // kana marks Big5 lacks (ー ・)
        "한국어달력",  // Hangul (KS X 1001)
    ])
    func bundledFontCoversOtherScriptsInEventTitles(bold: Bool, text: String) {
        #expect(text.unicodeScalars.filter { !PageFonts.hasGlyph($0) } == [])
        #expect(coreTextGlyphs(text, PageFont(size: 24, bold: bold).ctFont).filter { $0 == 0 } == [])
    }

    @Test func aMissingCharacterIsDetectable() {
        // private use: not in the font, drawn and measured as .notdef
        let font = PageFont(size: 24)
        #expect(coreTextGlyphs("\u{E000}\u{E001}", font.ctFont) == [0, 0])
        #expect(!PageFonts.hasGlyph("\u{E000}") && !PageFonts.hasGlyph("\u{E001}"))
        #expect(font.length("\u{E000}") == font.length("\u{E001}"))
    }

    @Test func hasGlyph() {
        #expect(PageFonts.hasGlyph("曆") && PageFonts.hasGlyph("A") && PageFonts.hasGlyph(" "))
        #expect(!PageFonts.hasGlyph("🎂") && !PageFonts.hasGlyph("\u{E000}"))
    }

    @Test func cleanDropsWhatTheFontCannotDraw() {
        #expect(PageFonts.clean("🎂 媽媽生日") == "媽媽生日")
        #expect(PageFonts.clean("會議\u{200D}🧑\u{200D}💻 準備") == "會議 準備")
        #expect(PageFonts.clean("Line\nbreak\ttab") == "Line break tab")
        #expect(PageFonts.clean("☕\u{FE0F} 咖啡") == "咖啡")  // U+2615 + variation selector
    }

    @Test func coverageComesFromTheFontsCharacterMap() {
        // not from how a renderer happens to draw a missing glyph
        let codepoints = PageFonts.codepoints
        #expect(codepoints.count > 20000)
        #expect(codepoints.contains(UInt32(0x66C6)) && codepoints.contains(0x4EEC) && codepoints.contains(0xD55C))  // 曆 们 한
        #expect(!codepoints.contains(0x1F382) && !codepoints.contains(0xE000))
    }

    @Test func invisibleFormatCharactersAreAlwaysDropped() {
        for scalar in "\u{200B}\u{200C}\u{200D}\u{2060}\u{FE0F}\u{FEFF}".unicodeScalars {
            #expect(!PageFonts.hasGlyph(scalar), "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
        // the font maps U+00AD SOFT HYPHEN, but as a format character it is not drawn either
        #expect(PageFonts.codepoints.contains(0xAD) && !PageFonts.hasGlyph("\u{AD}"))
    }

    /// Pillow's BASIC layout engine everywhere: no kerning, no ligatures, so a width is the sum
    /// of the characters' widths.
    @Test(arguments: [false, true])
    func widthsAreTheSumOfTheCharacters(bold: Bool) {
        let font = PageFont(size: 20, bold: bold)
        for pair in ["AV", "To", "Wa", "fi", "ffi", "LT", "會議", "1/2"] {
            #expect(font.length(pair) == Double(pair.unicodeScalars.map { font.advance($0) }.reduce(0, +)), "\(pair)")
        }
    }

    @Test func cleanComposesDecomposedAccents() {
        #expect(PageFonts.clean("Cafe\u{301} 會議") == "Caf\u{E9} 會議")
        #expect(PageFonts.clean("Cafe\u{301} 會議").unicodeScalars.count == 7)
    }

    @Test func cleanKeepsSimplifiedChineseKanaAndHangul() {
        #expect(PageFonts.clean("这是简体 カレンダー 한국어 달력") == "这是简体 カレンダー 한국어 달력")
    }

    @Test func boldAndRegularAreDifferentFiles() {
        #expect(PageFonts.url(bold: true) != PageFonts.url(bold: false))
        #expect(PageFonts.url(bold: true).deletingLastPathComponent() == PaperhuePages.fontsDirectory)
    }

    // MARK: Swift side

    /// The widths are read from the font's own tables; CoreText, which draws, must use the same
    /// glyph for every character and agree on the (unrounded) advance.
    @Test(arguments: [false, true])
    func coreTextDrawsTheGlyphsThatAreMeasured(bold: Bool) {
        let font = PageFont(size: 1000, bold: bold)  // 1000 px = font units: advances are exact
        let face = PageFace.face(bold: bold)
        var mismatched: [UInt32] = []
        for value in PageFonts.codepoints.sorted() {
            let scalar = Unicode.Scalar(value)!
            let glyph = coreTextGlyphs(String(scalar), font.ctFont)[0]
            var advance = CGSize.zero
            var g = glyph
            CTFontGetAdvancesForGlyphs(font.ctFont, .horizontal, &g, &advance, 1)
            if Int(glyph) != face.file.glyph(for: value) || advance.width != Double(font.advance(scalar)) {
                mismatched.append(value)
            }
        }
        #expect(mismatched.isEmpty, "\(mismatched.prefix(20).map { String($0, radix: 16) })")
    }

    /// The glyphs to draw sit where Pillow's BASIC layout puts them: one per code point
    /// (.notdef where the font lacks it), each after the whole-pixel advances before it.
    @Test(arguments: [false, true])
    func layoutPlacesEachGlyphAtPillowsPenPosition(bold: Bool) {
        let font = PageFont(size: 20, bold: bold)
        let text = "Q3 會議·AV\u{E000}x…"
        let run = font.layout(text)
        #expect(run.map(\.glyph) == coreTextGlyphs(text, font.ctFont))
        var x = 0
        for (scalar, placed) in zip(text.unicodeScalars, run) {
            #expect(placed.x == x, "\(scalar)")
            x += font.advance(scalar)
        }
        #expect(run.count == text.unicodeScalars.count && Double(x) == font.length(text))
        #expect(font.layout("").isEmpty)
    }

    @Test func sizesScaleTheAdvancesWithFreeTypesRounding() {
        // 1000 units at 20 px: 20 px. 555 units ("A" regular): 11.1 -> 11 px. 500 at 21: 10.5 -> 11.
        #expect(PageFont(size: 20).advance("會") == 20)
        #expect(PageFace.pixelAdvance(units: 555, size: 20, unitsPerEm: 1000) == 11)
        #expect(PageFace.pixelAdvance(units: 500, size: 21, unitsPerEm: 1000) == 11)
        #expect(PageFace.pixelAdvance(units: 500, size: 1, unitsPerEm: 1000) == 1)
        #expect(PageFace.pixelAdvance(units: 0, size: 40, unitsPerEm: 1000) == 0)
        // the 16.16 scale rounds up: 583 units at 18 px are 10.494 px, FreeType gives 11
        #expect(PageFace.pixelAdvance(units: 583, size: 18, unitsPerEm: 1000) == 11)
        #expect(PageFace.pixelAdvance(units: 656, size: 16, unitsPerEm: 1000) == 11)
    }

    @Test func theMiddleDotIsFullWidth() {
        // LAYOUTS.md 1.2: the separator carries its own spacing (18 px at 18 px)
        #expect(PageFont(size: PageText.noteSize).length(PageText.separator) == 18)
    }

    @Test func pageFontsAreValues() {
        #expect(PageFont(size: 20) == PageFont(size: 20, bold: false))
        #expect(PageFont(size: 20) != PageFont(size: 20, bold: true))
    }
}
