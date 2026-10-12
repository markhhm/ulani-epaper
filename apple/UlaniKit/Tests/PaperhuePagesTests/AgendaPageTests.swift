import Foundation
import PaperhueAgenda
import Testing
@testable import PaperhuePages

/// The agenda page (shared/LAYOUTS.md 5) against the Python reference: the golden renders in
/// shared/layouts/agenda/golden/ and every drawing call of render_agenda over many inputs
/// (Differential/page-expectations.json). Ports the agenda parts of python/tests/test_layouts.py.
@Suite struct AgendaPageTests {
    static let names = MonthPageTests.names
    static let taipei = TimeZone(secondsFromGMT: 8 * 3600)!

    @Test(arguments: names)
    func drawsExactlyTheGoldenText(name: String) throws {
        try expectGoldenText(.agenda, name)
    }

    /// The pixels are the golden's except glyph pixels, with the month page's rules and
    /// tolerances (MonthPageTests).
    ///
    /// Measured: every differing pixel is a glyph pixel; sample 8944 (38.7% of the golden's 23083
    /// glyph pixels), empty 1228 (11.0% of 11120), busy 10283 (37.7% of 27261), midday 7082
    /// (33.6% of 21059); glyph pixel counts within 2.0%; per string at most 12.5% farther than
    /// 1 px (墾丁三日遊, 20 px bold), none farther than 3 px.
    @Test(arguments: names)
    func matchesTheGoldenRenderUpToGlyphPixels(name: String) throws {
        try expectGoldenPixels(.agenda, name)
    }

    /// Every drawing call is the reference's, in order, for the fixtures over several days and
    /// zones, sync times through the day, a week across the new year, extreme inputs and seeded
    /// random agendas.
    @Test func drawsWhatTheReferenceDraws() throws {
        #expect(try GoldenPage.agenda.expectations().count >= 90)
        let texts = try expectReferenceOperations(.agenda).filter { $0.hasPrefix("text\t") }
        // the expectations reach every branch of both columns and the empty week
        for marker in ["進行中", "接下來", "今天稍後", "還有", "稍早已結束", "下一個行程", "今天沒有其他行程", "\t今天沒有行程",
                       "\t沒有行程", "接下來 6 天也沒有行程", "\t1月", "年12月28日", "全天", "\t至", "隔天", "…", "\t+",
                       "更新於 20"] {
            #expect(texts.contains { $0.contains(marker) }, "no case draws \(marker)")
        }
    }

    @Test(arguments: names)
    func textStaysOnTheCanvasDrawableAndNeverOverlaps(name: String) throws {
        expectTextOnTheCanvasDrawableAndApart(try GoldenPage.agenda.render(name))
    }

    @Test func noInkBelowTheBottomLine() throws {
        try expectNoInkBelowTheBottomLine(.agenda)
    }

    @Test func renderingIsDeterministic() throws {
        #expect(try GoldenPage.agenda.render("busy").pixels == GoldenPage.agenda.render("busy").pixels)
    }

    /// An event at 17:30 UTC is on the 13th in Taipei: tomorrow's first row on the 12th, the
    /// hero on the 13th.
    @Test func eventsInOtherTimeZonesLandOnTheirLocalDay() throws {
        let day = try #require(LocalDate(year: 2026, month: 10, day: 12))
        let late = OffsetDateTime(try #require(LocalDateTime(date: day, hour: 17, minute: 30)), utcOffset: 0)
        let landing = OffsetDateTime(late.wallClock.adding(seconds: 2 * 3600), utcOffset: 0)
        let data = AgendaData(events: [Event(title: "深夜航班", start: .dateTime(late), end: .dateTime(landing), color: "#4986e7")])
        func texts(_ day: Int) throws -> [String] {
            CalendarPages.agenda(data, today: try #require(LocalDate(year: 2026, month: 10, day: day)), zone: Self.taipei).drawnTexts
        }
        let on12th = try texts(12), on13th = try texts(13)
        #expect(on12th.contains("今天沒有行程"))
        let i = try #require(on12th.firstIndex(of: "13"))
        #expect(Array(on12th[i..<i + 5]) == ["13", "明天", "01:30", "03:30", "深夜航班"])
        #expect(on13th.contains("接下來") && on13th.contains("01:30 – 03:30"))
    }

    /// Synced at 13:30: the next event is the hero, the two that ended are counted.
    @Test func middayShowsWhatIsNextAndCountsWhatEnded() throws {
        let texts = try GoldenPage.agenda.render("midday").drawnTexts
        let i = try #require(texts.firstIndex(of: "接下來"))
        #expect(Array(texts[(i + 1)...(i + 2)]) == ["牙醫回診", "14:00 – 15:00"])
        #expect(texts.contains("稍早已結束 2 項"))  // 晨會 09:00-09:30 and the 10:00-11:30 review
    }

    /// Two syncs on the same day with nothing starting or ending in between draw the same page.
    @Test func theSyncStampIsTheDateOnly() throws {
        let f = try PageRepo.fixture("sample")
        var later = f.data
        later.fetchedAt = OffsetDateTime(try #require(LocalDateTime(date: f.today, hour: 8, minute: 45)), utcOffset: 8 * 3600)
        #expect(CalendarPages.agenda(f.data, today: f.today, zone: f.zone).pixels
                == CalendarPages.agenda(later, today: f.today, zone: f.zone).pixels)
    }
}
