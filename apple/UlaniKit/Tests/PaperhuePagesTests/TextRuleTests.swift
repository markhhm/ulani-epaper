import Testing
@testable import PaperhuePages

/// The text parts of python/tests/test_layouts.py, and the rules of LAYOUTS.md 1.1-1.2 with
/// numbers from the Python reference.
@Suite struct TextRuleTests {
    @Test(arguments: [
        ("讀完《原子習慣》", ["讀完《原子習", "慣》"]),  // 》 may not start a line
        ("繳交第三季報告，週五前", ["繳交第三季報", "告，週五前"]),  // neither may ，
        ("短標題", ["短標題"]),
        ("一二三四五六七八九十一二三四五六七八", ["一二三四五六七", "八九十一二三…"]),
    ])
    func wrapNeverStartsALineWithClosingPunctuation(text: String, lines: [String]) {
        #expect(PageText.wrap(text, font: PageFont(size: 40, bold: true), width: 7 * 40, maxLines: 2) == lines)
    }

    @Test(arguments: [
        ("", "（無標題）"), ("   ", "（無標題）"), ("🎂🎉", "（無法顯示的標題）"), ("🎂 生日", "生日"),
    ])
    func titles(raw: String, shown: String) {
        #expect(PageText.title(raw) == shown)
    }

    @Test func aMissingTitleIsUntitled() {
        #expect(PageText.title(nil) == PageText.untitled)
    }

    @Test func wrapCarriesTheCharacterBeforeClosingPunctuationDown() {
        let font = PageFont(size: 20)
        #expect(PageText.wrap("會議（重要）", font: font, width: 100, maxLines: 2) == ["會議（重", "要）"])
        #expect(PageText.wrap("一二三四五。", font: font, width: 100, maxLines: 2) == ["一二三四", "五。"])
    }

    @Test func wrapKeepsLatinWordsWholeAndSplitsOnlyWhatIsWiderThanTheLine() {
        let font = PageFont(size: 20)
        #expect(PageText.wrap("Hello world, this is long", font: font, width: 100, maxLines: .max)
                == ["Hello", "world, this", "is long"])
        #expect(PageText.wrap("Supercalifragilisticexpialidocious", font: font, width: 100, maxLines: 3)
                == ["Supercalif", "ragilistice", "xpialido…"])
    }

    @Test func fitKeepsWhatFits() {
        let font = PageFont(size: 18)
        #expect(font.length("Quarterly planning review") == 216)
        #expect(PageText.fit("Quarterly planning review", font: font, width: 216) == "Quarterly planning review")
        #expect(PageText.fit("會議記錄", font: font, width: 72) == "會議記錄")
    }

    @Test func fitNeverCutsALatinWordWhenItCanBackOffToASpace() {
        let font = PageFont(size: 18)
        let text = "Quarterly planning review"
        #expect(PageText.fit(text, font: font, width: 215) == "Quarterly planning…")
        #expect(PageText.fit(text, font: font, width: 170) == "Quarterly…")  // not "Quarterly plan…"
        #expect(PageText.fit(text, font: font, width: 100) == "Quarterly…")
        #expect(PageText.fit(text, font: font, width: 80) == "Quarte…")  // no space before the cut
        #expect(PageText.fit("Q3 Planning 會議", font: font, width: 100) == "Q3…")
    }

    @Test func fitCutsCJKAnywhere() {
        let font = PageFont(size: 18)
        #expect(PageText.fit("會議記錄", font: font, width: 71) == "會議…")
        #expect(PageText.fit("會議記錄", font: font, width: 40) == "會…")
    }

    @Test func fitDrawsTheEllipsisAloneOrNothing() {
        let font = PageFont(size: 18)
        #expect(font.length(PageText.ellipsis) == 18)
        #expect(PageText.fit("會議記錄", font: font, width: 18) == "…")
        #expect(PageText.fit("abc", font: font, width: 18) == "…")
        #expect(PageText.fit("會議記錄", font: font, width: 17) == "")
        #expect(PageText.fit("會議記錄", font: font, width: 0) == "")
    }

    @Test func typeScale() {
        #expect((PageText.syncSize, PageText.endTimeSize, PageText.noteSize, PageText.titleSize) == (16, 16, 18, 20))
        #expect(PageText.minimumCJKSize == 18)
        #expect((PageText.ellipsis, PageText.separator) == ("…", "·"))
        #expect((PageText.untitled, PageText.undrawable) == ("（無標題）", "（無法顯示的標題）"))
    }

    /// LAYOUTS.md 1.1: CJK is never set below 18 px (at 16-17 px Regular, 四 fills in); 16 px is
    /// for the sync stamp and digit-only times and dates. Bold CJK below 18 px is never used.
    @Test func cjkIsNeverSetBelow18Pixels() {
        #expect(PageText.mayDraw("更新於 10/12", size: 16, bold: false))
        #expect(PageText.mayDraw("更新於 2027/1/2", size: 16, bold: false))
        #expect(PageText.mayDraw("17:00", size: 16, bold: false))
        #expect(PageText.mayDraw("10/20", size: 16, bold: true))
        #expect(!PageText.mayDraw("四", size: 16, bold: false))
        #expect(!PageText.mayDraw("還有 3 項", size: 17, bold: false))
        #expect(!PageText.mayDraw("更新於 10/12", size: 16, bold: true))
        #expect(!PageText.mayDraw("カレンダー", size: 16, bold: false))
        #expect(!PageText.mayDraw("한국어", size: 16, bold: false))
        #expect(!PageText.mayDraw("（）", size: 16, bold: false))  // full-width punctuation
        #expect(PageText.mayDraw("四", size: 18, bold: false) && PageText.mayDraw("四", size: 18, bold: true))
        #expect(PageText.mayDraw("還有 3 項", size: 128, bold: true))
    }
}
