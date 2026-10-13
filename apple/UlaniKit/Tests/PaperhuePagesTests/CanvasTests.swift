import Foundation
import Testing
@testable import PaperhuePages

/// The page canvas and its primitives (shared/LAYOUTS.md 1.3): every shape is Pillow's to the
/// pixel (Differential/page-expectations.json), text sits where Pillow puts it.
@Suite struct CanvasTests {
    @Test func aNewPageIsWhite() {
        let page = PageCanvas()
        #expect(page.pixels.count == 800 * 480)
        #expect(Set(page.pixels) == [.white])
        #expect(page.drawnTexts.isEmpty)
        #expect(Set(page.indices) == [1])
    }

    /// Each primitive at every size the pages use and around them, alone on a white page, gives
    /// exactly the reference's pixels.
    @Test func shapesArePillowsPixelForPixel() throws {
        let shapes = try PageExpectations.load().shapes
        #expect(shapes.count >= 3000)
        var page = PageCanvas()
        var mismatches = 0
        for shape in shapes {
            draw(shape.call, on: &page)
            let runs = page.runs(shape.region)
            if fnv1a(runs) != shape.hash {
                mismatches += 1
                if mismatches <= 20 { Issue.record("\(shape.description): \(runs)") }
            }
            page.rect(shape.region.x0, shape.region.y0, shape.region.x1, shape.region.y1, fill: .white)
        }
        #expect(mismatches == 0)
    }

    @Test func textIsCleanedCutAndRecorded() {
        var page = PageCanvas()
        let width = page.text("🎂 生日\t快樂", x: 10, y: 40, size: 20, bold: true)
        #expect(page.drawnTexts == ["生日 快樂"])
        #expect(width == Int(PageFont(size: 20, bold: true).length("生日 快樂")))
        #expect(page.text("🎉", x: 10, y: 80, size: 20) == 0)  // nothing to draw: nothing recorded
        #expect(page.text("一二三四五六七八九十", x: 10, y: 120, size: 20, maxWidth: 70) == 60)
        #expect(page.drawnTexts == ["生日 快樂", "一二…"])
        #expect(page.pixels.contains(.black))
    }

    /// Baseline anchors: "rs" ends the advance at x, "ms" centres it with odd widths leaning
    /// left (Pillow rounds half the width up), and the point is rounded half to even.
    @Test(arguments: [
        (TextAnchor.left, 100.0, 100), (.right, 100.0, 100 - 39), (.centre, 100.0, 100 - 20),
        (.left, 100.5, 100), (.left, 101.5, 102), (.centre, 99.6, 100 - 20),
    ])
    func anchorsPlaceTheAdvance(anchor: TextAnchor, x: Double, left: Int) {
        let font = PageFont(size: 20)
        #expect(font.length("12:3") == 39)  // odd, so the centre needs rounding
        var page = PageCanvas()
        page.text("12:3", x: x, y: 50, size: 20, anchor: anchor)
        let run = page.textRuns[0]
        #expect(run.bounds.left <= left && run.bounds.right >= left + 39)
        #expect(page.operations == ["text\t\(Int(x.rounded(.toNearestOrEven)))\t50\t\(anchor.rawValue)\t20\t0\tblack\t12:3"])
        // the ink lies on the advance (Pillow's bbox of "12:3" is (0, -15, 39, 0)), above the baseline
        let ink = (0..<800 * 480).filter { page.pixels[$0] == .black }
        #expect(!ink.isEmpty)
        #expect(ink.allSatisfy { $0 % 800 >= left && $0 % 800 < left + 39 && $0 / 800 < 50 && $0 / 800 >= 50 - 16 })
    }

    /// Every glyph pixel lies inside its string's bounds, so the text mask of the golden
    /// comparison covers all of them.
    @Test func textBoundsCoverTheGlyphs() {
        var page = PageCanvas()
        for (size, base) in [(16, 20), (18, 45), (22, 75), (28, 110), (40, 160), (64, 240)] {
            page.text("國 Ég0（…）", x: 30, y: base, size: size, bold: size % 3 == 0)
        }
        page.text("31", x: 600, y: 300, size: 128, bold: true, anchor: .centre)
        let inside = (0..<800 * 480).filter { i in
            page.pixels[i] == .black && page.textRuns.contains { r in
                (r.bounds.left..<r.bounds.right).contains(i % 800) && (r.bounds.top..<r.bounds.bottom).contains(i / 800)
            }
        }
        #expect(inside.count == page.pixels.filter { $0 == .black }.count)
    }

    @Test func hairlinesAreEveryOtherPixel() {
        var page = PageCanvas()
        page.hairlineH(x0: 10, x1: 15, y: 3)
        page.hairlineV(x: 2, y0: 20, y1: 24)
        #expect((10...16).map { page[x: $0, y: 3] } == [.black, .white, .black, .white, .black, .white, .white])
        #expect((20...25).map { page[x: 2, y: $0] } == [.black, .white, .black, .white, .black, .white])
    }

    /// Yellow is pale on white: its bars, dots and cards get a black keyline; other colours don't.
    @Test func yellowGetsAKeyline() {
        var page = PageCanvas()
        page.bar(x: 10, y0: 10, y1: 50, colour: .yellow, width: 5)
        page.dot(cx: 40, cy: 20, r: 5, colour: .yellow)
        page.bar(x: 60, y0: 10, y1: 50, colour: .red, width: 5)
        #expect(page[x: 12, y: 10] == .black && page[x: 12, y: 30] == .yellow && page[x: 10, y: 30] == .black)
        #expect(page[x: 40, y: 15] == .black && page[x: 40, y: 20] == .yellow)
        #expect(page[x: 62, y: 10] == .red && page[x: 60, y: 30] == .red)
    }

    /// Draws one expectation call, as make_page_expectations.py's `call` does.
    private func draw(_ call: [Any], on page: inout PageCanvas) {
        let colour = { (value: Any) in PanelColour(rawValue: value as! String)! }
        let int = { (value: Any) in value as! Int }
        let double = { (value: Any) in (value as! NSNumber).doubleValue }
        switch call[0] as! String {
        case "bar": page.bar(x: int(call[1]), y0: int(call[2]), y1: int(call[3]), colour: colour(call[4]), width: int(call[5]))
        case "dot": page.dot(cx: double(call[1]), cy: double(call[2]), r: int(call[3]), colour: colour(call[4]))
        case "disc": page.disc(cx: double(call[1]), cy: double(call[2]), r: int(call[3]), fill: colour(call[4]))
        case "ring":
            page.ring(cx: double(call[1]), cy: double(call[2]), r: int(call[3]), colour: colour(call[4]), width: int(call[5]))
        case "rect": page.rect(int(call[1]), int(call[2]), int(call[3]), int(call[4]), fill: colour(call[5]))
        case "line":
            let points = (call[1] as! [[Int]]).map { (x: $0[0], y: $0[1]) }
            page.line(points, colour: colour(call[2]), width: int(call[3]))
        case "panel":
            page.panel(int(call[1]), int(call[2]), int(call[3]), int(call[4]), colour: colour(call[5]), radius: int(call[6]))
        case "hairline_h": page.hairlineH(x0: int(call[1]), x1: int(call[2]), y: int(call[3]))
        case "hairline_v": page.hairlineV(x: int(call[1]), y0: int(call[2]), y1: int(call[3]))
        default: Issue.record("unknown call \(call[0])")
        }
    }
}
