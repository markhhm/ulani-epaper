import Foundation
import PaperhueAgenda
import Testing
@testable import PaperhuePages

/// The to-do page (shared/LAYOUTS.md 6) against the Python reference: the golden renders in
/// shared/layouts/agenda/golden/ and every drawing call of render_todo over many inputs
/// (Differential/page-expectations.json). Ports the to-do parts of python/tests/test_layouts.py.
@Suite struct TodoPageTests {
    static let names = MonthPageTests.names

    @Test(arguments: names)
    func drawsExactlyTheGoldenText(name: String) throws {
        try expectGoldenText(.todo, name)
    }

    /// The pixels are the golden's except glyph pixels, with the month page's rules and
    /// tolerances (MonthPageTests).
    ///
    /// Measured: every differing pixel is a glyph pixel; sample and midday 5843 (33.1% of the
    /// golden's 17659 glyph pixels), empty 901 (15.8% of 5715), busy 7651 (38.9% of 19660);
    /// glyph pixel counts within 1.4%; per string at most 11.4% farther than 1 px (今天, the 20 px
    /// bold section header), none farther than 3 px.
    @Test(arguments: names)
    func matchesTheGoldenRenderUpToGlyphPixels(name: String) throws {
        try expectGoldenPixels(.todo, name)
    }

    /// Every drawing call is the reference's, in order, for the fixtures over several days,
    /// every flat layout and sections (1 to 201 tasks), the year boundary, extreme inputs and
    /// seeded random lists.
    @Test func drawsWhatTheReferenceDraws() throws {
        #expect(try PageKind.todo.expectations().count >= 80)
        let operations = try expectReferenceOperations(.todo)
        let texts = operations.filter { $0.hasPrefix("text\t") }
        // the expectations reach every kind, label, section and the empty state
        for marker in ["\t逾期", "\t今天", "\t之後", "\t未排定", "逾期 ", "昨天", "明天", "週", "還有", "2025年1月1日", "2027年3月1日",
                       "項已逾期", "項今天到期", "沒有待辦事項", "全部完成了", "（無標題）", "…", "更新於 20"] {
            #expect(texts.contains { $0.contains(marker) }, "no case draws \(marker)")
        }
        for shape in ["ring\t", "line\t", "hairline_h\t"] {
            #expect(operations.contains { $0.hasPrefix(shape) }, "no case draws \(shape)")
        }
    }

    @Test(arguments: names)
    func textStaysOnTheCanvasDrawableAndNeverOverlaps(name: String) throws {
        expectTextOnTheCanvasDrawableAndApart(try PageKind.todo.render(name))
    }

    @Test func noInkBelowTheBottomLine() throws {
        try expectNoInkBelowTheBottomLine(.todo)
    }

    @Test func renderingIsDeterministic() throws {
        #expect(try PageKind.todo.render("busy").pixels == PageKind.todo.render("busy").pixels)
    }

    /// The stamp is the sync date, never its time.
    @Test func theSyncStampIsTheDateOnly() throws {
        let f = try PageRepo.fixture("sample")
        var later = f.data
        later.fetchedAt = OffsetDateTime(try #require(LocalDateTime(date: f.today, hour: 8, minute: 45)), utcOffset: 8 * 3600)
        let page = CalendarPages.todo(later, today: f.today, zone: f.zone)
        #expect(page.pixels == CalendarPages.todo(f.data, today: f.today, zone: f.zone).pixels)
        #expect(page.drawnTexts.contains("更新於 10/12"))
    }
}
