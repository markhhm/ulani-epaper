import Foundation
import PaperhueAgenda
import Testing
import UlaniKit
@testable import PaperhuePages

/// The calendar pages on a background photo (shared/LAYOUTS.md 12) against the goldens
/// *_photo: drawn on the reference's own dithering of photo.json's background
/// (Differential/photo-background.png), since resampling may differ in detail.
@Suite struct PhotoPageTests {
    static let kinds: [GoldenPage] = [.month, .agenda, .todo, .day, .monthGrid]

    static let background = Result<Frame, any Error> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Differential/photo-background.png")
        return try Frame(indices: try goldenPixels(url).map { try #require($0).index })
    }

    @Test(arguments: kinds)
    func drawsExactlyTheGoldenText(kind: GoldenPage) throws {
        let f = try PageRepo.fixture("photo")
        let url = PageRepo.agendaGoldens.appendingPathComponent("\(kind.rawValue)_photo.txt")
        let golden = try String(contentsOf: url, encoding: .utf8)
        let background = try Self.background.get()
        #expect(kind.render(f.data, today: f.today, zone: f.zone, background: background).drawnTexts
                == golden.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init))
    }

    /// Every mark (bars, dots, discs, rings, hairlines, the "+") is the golden's pixel for pixel
    /// on the same background. Text pixels may differ only by its white fill, its black outline
    /// or what lies under it: CoreText's glyphs differ a little from FreeType's hinted ones (see
    /// MonthPageTests), and the outline widens that by up to 4 px.
    ///
    /// Measured: differing text pixels are month 9040 of 34878 (26%), agenda 13786 of 46815 (29%),
    /// todo 9274 of 36313 (26%), day 8848 of 38858 (23%), monthgrid 6238 of 29452 (21%) of the
    /// golden's text pixels (fill and outline); every mark is exact.
    @Test(arguments: kinds)
    func matchesTheGoldenRenderUpToTextPixels(kind: GoldenPage) throws {
        let f = try PageRepo.fixture("photo")
        let background = try Self.background.get()
        let page = kind.render(f.data, today: f.today, zone: f.zone, background: background)
        let bare = kind.render(f.data, today: f.today, zone: f.zone, glyphs: false, background: background)
        let golden = try goldenPixels(PageRepo.agendaGoldens.appendingPathComponent("\(kind.rawValue)_photo.png"))
        let c = GoldenComparison(page: page, bare: bare, golden: golden)
        #expect(c.errors.isEmpty, "\(c.errors.count) pixels differ outside the text, first \(c.errors.prefix(10))")
        let textPixels = (0..<golden.count).filter { golden[$0] != bare.pixels[$0] }.count
        #expect(Double(c.differentPixels) <= 0.35 * Double(textPixels), "\(c.differentPixels) of \(textPixels)")
    }

    @Test func outlinesFollowTheTextSize() {
        #expect([8, 18, 24, 26, 40, 72, 180].map(PageCanvas.photoOutline(size:)) == [1, 1, 2, 2, 3, 4, 4])
        #expect(PageCanvas.outlineOffsets(1).count == 9)  // the diagonals too
        #expect(!PageCanvas.outlineOffsets(3).contains { $0 == (3, 2) || $0 == (3, 3) })
        #expect(PageCanvas.outlineOffsets(3).contains { $0 == (3, 1) })
    }

    @Test func withoutABackgroundNothingChanges() throws {
        let f = try PageRepo.fixture("sample")
        let golden = try GoldenPage.month.render("sample").pixels
        #expect(CalendarPages.month(f.data, today: f.today, zone: f.zone).pixels == golden)
    }
}
