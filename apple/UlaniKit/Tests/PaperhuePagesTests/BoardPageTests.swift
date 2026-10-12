import Foundation
import PaperhueAgenda
import Testing
@testable import PaperhuePages

/// The message board pages (shared/BOARD.md "Drawing", shared/LAYOUTS.md 9) against the Python
/// reference: the golden renders in shared/layouts/board/golden/ (every fixture there, found by
/// listing the folder, so regenerated goldens need no change here) and every drawing call of
/// render_board and render_message over many inputs (Differential/board-expectations.json).
/// Ports python/tests/test_board_layouts.py.
@Suite struct BoardPageTests {
    // MARK: Goldens

    /// Times, counts and wrapped lines: the drawn strings are the golden's exactly, in order.
    @Test(arguments: BoardRepo.goldens())
    func drawsExactlyTheGoldenText(golden: String) throws {
        let (kind, f) = try BoardRepo.golden(golden)
        let text = try String(contentsOf: BoardRepo.goldenFolder.appendingPathComponent("\(golden).txt"), encoding: .utf8)
        #expect(draw(kind, f.notes, f.zone).drawnTexts
                == text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init))
    }

    /// The pixels are the golden's except glyph pixels, with the month page's rules and
    /// tolerances (MonthPageTests.matchesTheGoldenRenderUpToGlyphPixels): FreeType hints the
    /// outlines, CoreText does not.
    @Test(arguments: BoardRepo.goldens())
    func matchesTheGoldenRenderUpToGlyphPixels(golden: String) throws {
        let (kind, f) = try BoardRepo.golden(golden)
        let page = draw(kind, f.notes, f.zone)
        let bare = draw(kind, f.notes, f.zone, glyphs: false)
        let pixels = try goldenPixels(BoardRepo.goldenFolder.appendingPathComponent("\(golden).png"))
        #expect(!pixels.contains(nil), "the golden has colours outside the palette")
        let c = GoldenComparison(page: page, bare: bare, golden: pixels)
        #expect(c.errors.isEmpty, "\(c.errors.count) pixels differ outside the glyphs, first \(c.errors.prefix(10))")
        for run in c.runs {
            let ink = Double(max(run.ink, run.goldenInk))
            #expect(Double(run.farther1) <= Glyphs.fartherThan1px * ink,
                    "\(run.text): \(run.farther1) of \(Int(ink)) glyph pixels are more than 1 px from the golden's")
            #expect(run.farther3 == 0, "\(run.text): \(run.farther3) glyph pixels are more than 3 px from the golden's")
        }
        let ink = c.runs.reduce(0) { $0 + $1.ink }, goldenInk = c.runs.reduce(0) { $0 + $1.goldenInk }
        let different = c.runs.reduce(0) { $0 + $1.different }
        #expect(Double(different) <= Glyphs.pageDifferent * Double(goldenInk),
                "\(different) of \(goldenInk) glyph pixels differ")
        #expect(Double(abs(ink - goldenInk)) <= Glyphs.pageInk * Double(goldenInk),
                "the text is \(ink) pixels here, \(goldenInk) in the golden")
        #expect(c.differentPixels == different, "only glyph pixels differ")
    }

    /// Every string is on the canvas, drawable, and no two overlap by 2 px or more in both axes.
    @Test(arguments: BoardRepo.goldens())
    func textStaysOnTheCanvasDrawableAndNeverOverlaps(golden: String) throws {
        let (kind, f) = try BoardRepo.golden(golden)
        let runs = draw(kind, f.notes, f.zone).textRuns
        #expect(!runs.isEmpty)
        for run in runs {
            let b = run.bounds
            #expect(b.left >= 0 && b.top >= 0 && b.right <= 800 && b.bottom <= 480, "\(run.text) is off the canvas")
            #expect(run.text.unicodeScalars.allSatisfy { $0 == " " || PageFonts.hasGlyph($0) }, "\(run.text)")
        }
        for (i, a) in runs.enumerated() {
            for b in runs[(i + 1)...] {
                let w = min(a.bounds.right, b.bounds.right) - max(a.bounds.left, b.bounds.left)
                let h = min(a.bounds.bottom, b.bounds.bottom) - max(a.bounds.top, b.bounds.top)
                #expect(!(w >= 2 && h >= 2), "\(a.text) overlaps \(b.text)")
            }
        }
    }

    // MARK: The reference's drawing calls

    /// Every drawing call (position, size, colour, string, card) is the reference's, in order:
    /// the fixtures, the inputs of test_board_layouts.py, malformed notes and seeded random
    /// boards in several zones.
    @Test func drawsWhatTheReferenceDraws() throws {
        let cases = try BoardExpectations.load()
        #expect(cases.count >= 60)
        for c in cases {
            for (kind, expected) in [("board", c.board), ("message", c.message)] {
                let page = draw(kind, c.notes, c.zone)
                if page.operations != expected {
                    let i = zip(page.operations, expected).enumerated().first { $1.0 != $1.1 }?.offset
                        ?? min(page.operations.count, expected.count)
                    Issue.record("""
                        \(c.name) \(kind): call \(i) is \(i < page.operations.count ? page.operations[i] : "missing"), \
                        expected \(i < expected.count ? expected[i] : "nothing")
                        """)
                }
            }
        }
        let texts = cases.flatMap { $0.board + $0.message }.filter { $0.hasPrefix("text\t") }
        for marker in ["…", "最新 6 則，共 8 則", "（無法顯示的留言）", "還沒有留言", "\t120\t", "\t20\t1\t"] {
            #expect(texts.contains { $0.contains(marker) }, "no case draws \(marker)")
        }
    }

    /// No ink from y = 462 down on the fixtures, as test_board_layouts.py checks. (Not on every
    /// input: the reference centres the big message on the "國" box, so a Latin descender on
    /// the last line can reach below it, and the Swift page does the same.)
    @Test(arguments: BoardRepo.goldens())
    func noInkBelowTheBottomLine(golden: String) throws {
        let (kind, f) = try BoardRepo.golden(golden)
        #expect(draw(kind, f.notes, f.zone).pixels[(PageGeometry.bottom * 800)...].allSatisfy { $0 == .white })
    }

    @Test func renderingIsDeterministic() throws {
        let f = try BoardRepo.fixture("six")
        #expect(BoardPages.board(f.notes, zone: f.zone).pixels == BoardPages.board(f.notes, zone: f.zone).pixels)
        #expect(BoardPages.message(f.notes, zone: f.zone).pixels == BoardPages.message(f.notes, zone: f.zone).pixels)
    }

    // MARK: Board

    /// 1: full width, 2 and 3: columns, 4: 2 x 2, 5-6: 3 x 2, newest first; a point just inside
    /// each cell's bottom-right corner has the note's colour (LAYOUTS.md 9.1 geometry).
    @Test(arguments: [(1, 1, 1), (2, 2, 1), (3, 3, 1), (4, 2, 2), (5, 3, 2), (6, 3, 2)])
    func cardsFillTheGridNewestFirst(n: Int, cols: Int, rows: Int) {
        let colours: [PanelColour] = [.blue, .red, .green, .orange, .blue, .red]
        let notes = (0..<n).map { note("記得澆花", colours[$0].rawValue, id: "0000000\($0)") }
        let page = BoardPages.board(notes, zone: tpe)
        func bottomRight(_ i: Int) -> (x: Int, y: Int) {
            let cw = (744 - Double(cols - 1) * 16) / Double(cols), ch = (378 - Double(rows - 1) * 16) / Double(rows)
            let (r, c) = i.quotientAndRemainder(dividingBy: cols)
            return (Int((28 + Double(c) * (cw + 16) + cw).rounded(.toNearestOrEven)) - 13,
                    Int((84 + Double(r) * (ch + 16) + ch).rounded(.toNearestOrEven)) - 13)
        }
        for i in 0..<n {
            let p = bottomRight(i)
            #expect(page[x: p.x, y: p.y] == colours[i], "card \(i)")
        }
        if n == 5 {
            let p = bottomRight(5)
            #expect(page[x: p.x, y: p.y] == .white, "the sixth cell stays empty")
        }
    }

    @Test func moreThanSixShowsTheNewestSix() {
        let texts = BoardPages.board((0..<8).map { note("第\($0)則", id: "0000000\($0)") }, zone: tpe).drawnTexts
        #expect(texts.contains("最新 6 則，共 8 則"))
        #expect(texts.contains("第0則") && texts.contains("第5則") && !texts.contains("第6則"))
    }

    @Test(arguments: [("yellow", PanelColour.black), ("orange", .black), ("green", .white), ("blue", .white),
                      ("red", .white)])
    func cardTextColour(colour: String, ink: PanelColour) {
        let texts = drawn(BoardPages.board([note("記得澆花", colour)], zone: tpe))
        #expect(Set(texts.filter { ["記得澆花", "10/12 14:03"].contains($0.text) }.map(\.fill)) == [ink])
    }

    @Test func theYellowCardHasABlackKeyline() {
        let yellow = BoardPages.board([note("x", "yellow")], zone: tpe)
        #expect(yellow[x: 400, y: 84] == .black && yellow[x: 400, y: 85] == .yellow)
        #expect(BoardPages.board([note("x", "blue")], zone: tpe)[x: 400, y: 84] == .blue)
    }

    @Test func cardTextIsAsLargeAsFits() throws {
        let short = drawn(BoardPages.board([note("短")], zone: tpe))
        #expect(short.filter { $0.text == "短" }.map(\.size) == [44])
        #expect(short.filter { $0.text == "10/12 14:03" }.map(\.size) == [18])
        let long = try BoardRepo.fixture("long")
        let body = drawn(BoardPages.board(long.notes, zone: long.zone)).dropFirst(2).dropLast()  // title, count; time
        let sizes = Set(body.map(\.size))
        #expect(sizes.count == 1 && sizes.first! < 30 && BoardPage.cardSizes.contains(sizes.first!))
        #expect(!body.contains { $0.text.hasSuffix("…") }, "it shrank until all of it fits")
    }

    @Test func textThatNeverFitsEndsWithAnEllipsis() {
        let notes = (0..<6).map { note(String(repeating: "字", count: 300), id: "0000000\($0)") }
        let body = drawn(BoardPages.board(notes, zone: tpe)).filter { $0.text.contains("字") }
        #expect(Set(body.map(\.size)) == [20])
        #expect(body.filter { $0.text.hasSuffix("…") }.count == 6, "one cut line per card")
    }

    @Test func lineBreaksAreKept() {
        #expect(BoardPages.board([note("買牛奶\n繳電費")], zone: tpe).drawnTexts[2..<4] == ["買牛奶", "繳電費"])
        // empty and undrawable lines leave no gap
        #expect(BoardPages.board([note("買牛奶\n\n🎂\n繳電費")], zone: tpe).drawnTexts[2..<4] == ["買牛奶", "繳電費"])
    }

    @Test(arguments: ["🎂🎉", "\u{200D}"])
    func undrawableNotesSaySo(text: String) {
        for page in [BoardPages.board([note(text)], zone: tpe), BoardPages.message([note(text)], zone: tpe)] {
            #expect(page.drawnTexts.joined().contains("（無法顯示的留言）"))  // may wrap
        }
    }

    @Test func timesAreShownInTheGivenZone() throws {
        let utcNote = note("x", at: "2026-10-11T17:05:00+00:00")
        #expect(BoardPages.board([utcNote], zone: tpe).drawnTexts.contains("10/12 01:05"))
        #expect(BoardPages.board([utcNote], zone: try #require(TimeZone(secondsFromGMT: 0))).drawnTexts.contains("10/11 17:05"))
    }

    @Test func emptyState() {
        for page in [BoardPages.board([], zone: tpe), BoardPages.message([], zone: tpe)] {
            #expect(page.drawnTexts.dropFirst() == ["還沒有留言", "在 Paperhue 輸入留言，就會顯示在這裡"])
        }
    }

    // MARK: One big message

    @Test func messageShowsOnlyTheNewestNote() {
        let notes = [note("新的", at: "2026-10-12T18:00:00+08:00", id: "00000001"), note("舊的", id: "00000002")]
        let texts = drawn(BoardPages.message(notes, zone: tpe))
        #expect(texts.map { "\($0.text) \($0.size)" } == ["留言 28", "10/12 18:00 18", "新的 120"])
        #expect(texts[0].fill == .red, "the title is red")
    }

    @Test(arguments: [("yellow", PanelColour.black), ("orange", .black), ("red", .red), ("blue", .blue), ("green", .green)])
    func messageColour(colour: String, ink: PanelColour) {
        #expect(drawn(BoardPages.message([note("出門了", colour)], zone: tpe)).filter { $0.text == "出門了" }.map(\.fill) == [ink])
    }

    @Test func messageIsCentred() throws {
        let run = try #require(BoardPages.message([note("出門了")], zone: tpe).textRuns.first { $0.text == "出門了" })
        #expect(abs(Double(run.bounds.left + run.bounds.right) / 2 - 400) <= 2)
        #expect(abs(Double(run.bounds.top + run.bounds.bottom) / 2 - Double(84 + 462) / 2) <= 6)
    }

    @Test func messageShrinksThenCuts() {
        var sizes: [Int] = []
        let long = String(repeating: "字", count: 300)
        for text in ["好", "晚餐在冰箱，微波 3 分鐘就好", String(repeating: "字", count: 60), long] {
            let body = drawn(BoardPages.message([note(text)], zone: tpe)).dropFirst(2)
            sizes.append(body.first!.size)
            #expect(body.last!.text.hasSuffix("…") == (text == long))
        }
        #expect(sizes.first == 120 && sizes == sizes.sorted(by: >) && sizes.last == 30)
    }

    @Test func messageLinesAreBalanced() {
        // not a long line over a short one
        #expect(BoardPages.message([note("（無法顯示的留言）")], zone: tpe).drawnTexts.dropFirst(2) == ["（無法顯示", "的留言）"])
    }

    @Test func fitNotePicksTheLargestSizeThatHoldsEverything() {
        let w = PageFont(size: 44, bold: true).length("字")
        let fitted = BoardPage.fitNote([String(repeating: "字", count: 8)], sizes: BoardPage.cardSizes, width: w * 4,
                                       height: 200)
        #expect(fitted.size == 44 && fitted.lines == ["字字字字", "字字字字"])
        let cut = BoardPage.fitNote([String(repeating: "字", count: 100)], sizes: BoardPage.cardSizes, width: 200, height: 60)
        #expect(cut.size == 20 && cut.lines.last!.hasSuffix("…"))
    }

    // MARK: Helpers

    private let tpe = TimeZone(secondsFromGMT: 8 * 3600)!

    private func note(_ text: String, _ color: String = "yellow", at: String = "2026-10-12T14:03:00+08:00",
                      id: String = "a1b2c3d4") -> Note {
        Note(id: id, text: text, at: at, color: color)
    }

    /// "board" or "message", optionally without glyph pixels (what lies under the text).
    private func draw(_ kind: String, _ notes: [Note], _ zone: TimeZone, glyphs: Bool = true) -> PageCanvas {
        var page = PageCanvas()
        page.drawsGlyphs = glyphs
        if kind == "board" {
            BoardPage.drawBoard(&page, notes, zone)
        } else {
            BoardPage.drawMessage(&page, notes, zone)
        }
        return page
    }

    /// Each drawn string with its size and colour, in drawing order.
    private func drawn(_ page: PageCanvas) -> [(text: String, size: Int, fill: PanelColour)] {
        page.operations.filter { $0.hasPrefix("text\t") }.map { op in
            let f = op.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return (f[7], Int(f[4])!, PanelColour(rawValue: f[6])!)
        }
    }
}

/// The board fixtures and goldens in the repository.
enum BoardRepo {
    static let fixtures = PageRepo.root.appendingPathComponent("shared/layouts/board")
    static let goldenFolder = fixtures.appendingPathComponent("golden")

    static func fixture(_ name: String) throws -> BoardFixture {
        try BoardFixture(contentsOf: fixtures.appendingPathComponent("\(name).json"))
    }

    /// "board_six", "message_six", ...: both pages of every fixture in the folder.
    static func goldens() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fixtures.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().flatMap { name in
            ["board", "message"].map { "\($0)_\(name.dropLast(5))" }
        }
    }

    /// The page kind and fixture of a golden's name.
    static func golden(_ name: String) throws -> (kind: String, fixture: BoardFixture) {
        let parts = name.split(separator: "_", maxSplits: 1).map(String.init)
        return (parts[0], try fixture(parts[1]))
    }
}

/// Differential/board-expectations.json.
struct BoardExpectations: Sendable {
    let name: String
    let notes: [Note]
    let zone: TimeZone
    let board: [String]
    let message: [String]

    static func load() throws -> [BoardExpectations] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Differential/board-expectations.json")
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(raw["cases"] as? [[String: Any]]).map { c in
            let notes = (c["notes"] as! [[String]]).map { Note(id: $0[0], text: $0[1], at: $0[2], color: $0[3]) }
            return BoardExpectations(name: c["name"] as! String, notes: notes, zone: try PageRepo.zone(c["zone"] as! String),
                                     board: c["board"] as! [String], message: c["message"] as! [String])
        }
    }
}
