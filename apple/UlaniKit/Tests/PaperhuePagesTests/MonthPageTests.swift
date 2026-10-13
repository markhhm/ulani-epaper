import Foundation
import PaperhueAgenda
import Testing
@testable import PaperhuePages

/// The month page (shared/LAYOUTS.md 4) against the Python reference: the golden renders in
/// shared/layouts/agenda/golden/ and every drawing call of render_month over many inputs
/// (Differential/page-expectations.json). Ports the month parts of python/tests/test_layouts.py.
@Suite struct MonthPageTests {
    static let names = ["sample", "empty", "busy", "midday"]

    private func render(_ name: String) throws -> PageCanvas {
        let f = try PageRepo.fixture(name)
        return CalendarPages.month(f.data, today: f.today, zone: f.zone)
    }

    /// Times, counts and labels: the drawn strings are the golden's exactly, in order.
    @Test(arguments: names)
    func drawsExactlyTheGoldenText(name: String) throws {
        try expectGoldenText(.month, name)
    }

    /// The pixels are the golden's except glyph pixels.
    ///
    /// The reference rasterises text with FreeType, which hints the outlines (moves stems and
    /// the tops of ideographs onto whole pixels) before its 1-bit rendering; CoreText does not
    /// hint (`GlyphRaster`), so a stroke can land a row or two away, mostly in 20-28 px CJK.
    /// Nothing else may differ:
    /// * outside every string's box (its bounds plus 2 px): identical, no tolerance;
    /// * inside: a pixel may differ only between the string's colour and what the page has
    ///   under the text (drawn again without glyphs); any other difference is an error;
    /// * per string: at most `Glyphs.fartherThan1px` of its glyph pixels (here or in the golden)
    ///   have no glyph pixel of the other within 1 px, and none is more than 3 px from one;
    /// * per page: the glyph pixels that differ are at most `Glyphs.pageDifferent` of the
    ///   golden's glyph pixels, and the two counts are within `Glyphs.pageInk` of each other
    ///   (so the text is neither shifted nor bolder or lighter as a whole).
    ///
    /// Measured (Pillow 12.3 / FreeType 2.14 against CoreText on macOS 26): every differing
    /// pixel is a glyph pixel; sample 5954 of 384000 pixels (30.6% of the golden's 19434 glyph
    /// pixels), empty 2195 (16.4% of 13393), busy 6370 (31.8% of 20006), midday 5514 (29.5% of
    /// 18719); glyph pixel counts within 1.6%; per string at most 12.5% farther than 1 px
    /// (墾丁三日遊, 20 px bold), none farther than 3 px; the grid's day numerals differ by 1 to 25
    /// pixels, today's 128 px numeral by 85 of its 5658.
    @Test(arguments: names)
    func matchesTheGoldenRenderUpToGlyphPixels(name: String) throws {
        try expectGoldenPixels(.month, name)
    }

    /// Every drawing call (position, size, colour, string, shape) is the reference's, in order,
    /// for the fixtures over several days and zones, 4- to 6-week months, extreme inputs and
    /// seeded random agendas.
    @Test func drawsWhatTheReferenceDraws() throws {
        #expect(try GoldenPage.month.expectations().count >= 80)
        let operations = try expectReferenceOperations(.month)
        // the expectations reach every branch of the panel
        let texts = operations.filter { $0.hasPrefix("text\t") }
        for marker in ["還有", "稍早已結束", "下一個行程", "明天", "近期沒有行程", "今天沒有其他行程", "今天沒有行程", "全天",
                       "至", "第 ", "\t+", "（無標題）", "（無法顯示的標題）", "…", "隔天", "更新於 20"] {
            #expect(texts.contains { $0.contains(marker) }, "no case draws \(marker)")
        }
        #expect(operations.contains { $0.hasPrefix("plus\t") }, "no day with a +")
        #expect(operations.contains { $0.hasPrefix("dot\t") && $0.hasSuffix("yellow") })
    }

    @Test(arguments: ["2026-02-14", "2026-08-20", "2026-08-31", "2026-03-01", "2026-12-31", "2027-01-01"])
    func handlesFourFiveAndSixWeekMonths(day: String) throws {
        let f = try PageRepo.fixture("sample")
        let today = try #require(LocalDate(iso: day))
        let page = CalendarPages.month(f.data, today: today, zone: f.zone)
        #expect(Set(page.pixels).count >= 2)
        #expect(page.drawnTexts.contains(String(LocalDate.daysInMonth(year: today.year, month: today.month))))
    }

    @Test func todayIsMarkedInRed() throws {
        #expect(try render("empty").pixels.contains(.red))
    }

    @Test func renderingIsDeterministic() throws {
        #expect(try render("busy").pixels == render("busy").pixels)
    }

    /// Two syncs on the same day with nothing starting or ending in between draw the same page,
    /// so the device skips it (sample: the first event is at 09:00).
    @Test func theSyncStampIsTheDateOnly() throws {
        let f = try PageRepo.fixture("sample")
        var later = f.data
        later.fetchedAt = OffsetDateTime(try #require(LocalDateTime(date: f.today, hour: 8, minute: 45)), utcOffset: 8 * 3600)
        #expect(CalendarPages.month(f.data, today: f.today, zone: f.zone).pixels
                == CalendarPages.month(later, today: f.today, zone: f.zone).pixels)
        #expect(CalendarPages.month(later, today: f.today, zone: f.zone).drawnTexts.contains("更新於 10/12"))
    }

    /// Every string is on the canvas, drawable, and no two overlap by 2 px or more in both axes.
    @Test(arguments: names)
    func textStaysOnTheCanvasDrawableAndNeverOverlaps(name: String) throws {
        expectTextOnTheCanvasDrawableAndApart(try render(name))
    }

    /// Nothing below y = 462 (LAYOUTS.md 1), on every page the reference was checked on.
    @Test func noInkBelowTheBottomLine() throws {
        try expectNoInkBelowTheBottomLine(.month)
    }

    @Test func extremesDoNotBreakThePage() throws {
        let f = try PageRepo.fixture("sample")
        var data = f.data
        let at = OffsetDateTime(try #require(LocalDateTime(date: f.today, hour: 8, minute: 0)), utcOffset: 8 * 3600)
        let hour = OffsetDateTime(at.wallClock.adding(seconds: 3600), utcOffset: 8 * 3600)
        data.events += [Event(title: String(repeating: "超長標題", count: 75), start: .dateTime(at), end: .dateTime(hour), color: "#gggggg"),
                        Event(title: "", start: .dateTime(at), end: .dateTime(at))]
        let page = CalendarPages.month(data, today: f.today, zone: f.zone)
        #expect(page.drawnTexts.contains("（無標題）"))
        #expect(page.drawnTexts.contains { $0.hasPrefix("超長標題") && $0.hasSuffix("…") })
    }
}
