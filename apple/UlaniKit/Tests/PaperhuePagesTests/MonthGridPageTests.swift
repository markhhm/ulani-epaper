import Foundation
import PaperhueAgenda
import Testing
@testable import PaperhuePages

/// The full month page (月曆, id monthgrid; Python: render_monthgrid) against the Python
/// reference: the golden renders in shared/layouts/agenda/golden/ and every drawing call over
/// the month page's inputs, 4- to 6-week months included (Differential/page-expectations.json
/// "monthgrids").
@Suite struct MonthGridPageTests {
    static let names = MonthPageTests.names

    @Test(arguments: names)
    func drawsExactlyTheGoldenText(name: String) throws {
        try expectGoldenText(.monthGrid, name)
    }

    @Test(arguments: names)
    func matchesTheGoldenRenderUpToGlyphPixels(name: String) throws {
        try expectGoldenPixels(.monthGrid, name)
    }

    @Test func drawsWhatTheReferenceDraws() throws {
        #expect(try GoldenPage.monthGrid.expectations().count >= 60)
        let ops = try expectReferenceOperations(.monthGrid)
        #expect(ops.contains { $0.hasPrefix("plus\t") }, "no day with a +")
        #expect(ops.contains { $0.hasPrefix("disc\t") }, "no today")
        #expect(ops.contains { $0.hasPrefix("text\t") && $0.contains("…") }, "no short title cut")
    }

    @Test(arguments: names)
    func textStaysOnTheCanvasDrawableAndNeverOverlaps(name: String) throws {
        expectTextOnTheCanvasDrawableAndApart(try GoldenPage.monthGrid.render(name))
    }

    @Test func noInkBelowTheBottomLine() throws {
        try expectNoInkBelowTheBottomLine(.monthGrid)
    }
}
