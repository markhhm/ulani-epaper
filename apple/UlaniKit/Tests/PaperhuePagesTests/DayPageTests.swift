import Foundation
import PaperhueAgenda
import Testing
@testable import PaperhuePages

/// The day page (日; Python: render_day) against the Python reference: the golden renders in
/// shared/layouts/agenda/golden/ and every drawing call over the month page's inputs
/// (Differential/page-expectations.json "days").
@Suite struct DayPageTests {
    static let names = MonthPageTests.names

    @Test(arguments: names)
    func drawsExactlyTheGoldenText(name: String) throws {
        try expectGoldenText(.day, name)
    }

    @Test(arguments: names)
    func matchesTheGoldenRenderUpToGlyphPixels(name: String) throws {
        try expectGoldenPixels(.day, name)
    }

    @Test func drawsWhatTheReferenceDraws() throws {
        #expect(try GoldenPage.day.expectations().count >= 60)
        let texts = try expectReferenceOperations(.day).filter { $0.hasPrefix("text\t") }
        // the expectations reach every branch: events, all-day line, overflow, the empty day
        for marker in ["\t星期", "\t今天沒有行程", "\t下一個行程", "\t近期沒有行程", "全天", "還有", "更新於 20"] {
            #expect(texts.contains { $0.contains(marker) }, "no case draws \(marker)")
        }
    }

    @Test(arguments: names)
    func textStaysOnTheCanvasDrawableAndNeverOverlaps(name: String) throws {
        expectTextOnTheCanvasDrawableAndApart(try GoldenPage.day.render(name))
    }

    @Test func noInkBelowTheBottomLine() throws {
        try expectNoInkBelowTheBottomLine(.day)
    }
}
