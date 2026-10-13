import Foundation
import Testing
import UlaniKit
@testable import PaperhuePages

/// The card page (shared/CARDS.md "Drawing") against the Python reference: the golden renders in
/// shared/layouts/card/golden/ and every drawing call of render_card over many cards
/// (Differential/card-expectations.json). Ports python/tests/test_card_layouts.py.
@Suite struct CardPageTests {
    // MARK: Goldens

    @Test(arguments: CardRepo.names)
    func drawsExactlyTheGoldenText(name: String) throws {
        let golden = try String(contentsOf: CardRepo.goldens.appendingPathComponent("card_\(name).txt"), encoding: .utf8)
        #expect(try CardRepo.render(name).drawnTexts
                == golden.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init))
    }

    /// The cards on a colour: the pixels are the golden's except glyph pixels, with the month
    /// page's rules and tolerances (MonthPageTests.matchesTheGoldenRenderUpToGlyphPixels).
    /// Measured: lines 1490 of 18603 glyph pixels differ (8%), quote 2224 of 24529 (9%), status
    /// 905 of 28351 (3%).
    @Test(arguments: ["lines", "quote", "status"])
    func matchesTheGoldenRenderUpToGlyphPixels(name: String) throws {
        let c = try CardRepo.comparison(name)
        #expect(c.errors.isEmpty, "\(c.errors.count) pixels differ outside the glyphs, first \(c.errors.prefix(10))")
        for run in c.runs {
            let ink = Double(max(run.ink, run.goldenInk))
            #expect(Double(run.farther1) <= Glyphs.fartherThan1px * ink,
                    "\(run.text): \(run.farther1) of \(Int(ink)) glyph pixels are more than 1 px from the golden's")
            #expect(run.farther3 == 0, "\(run.text): \(run.farther3) glyph pixels are more than 3 px from the golden's")
        }
        #expect(Double(c.different) <= Glyphs.pageDifferent * Double(c.goldenInk),
                "\(c.different) of \(c.goldenInk) glyph pixels differ")
        #expect(Double(abs(c.ink - c.goldenInk)) <= Glyphs.pageInk * Double(c.goldenInk),
                "the text is \(c.ink) pixels here, \(c.goldenInk) in the golden")
        #expect(c.differentPixels == c.different, "only glyph pixels differ")
    }

    /// The captioned photo, drawn on the reference's own dithering of it (as PhotoPageTests): the
    /// photo is the golden's pixel for pixel; text pixels may differ only by the text's white,
    /// its black outline or the photo under it (the outline widens CoreText's small differences
    /// from FreeType's glyphs by 3 px). Measured: 4490 of 45760 text pixels (10%) differ.
    @Test func theMemeMatchesTheGoldenRenderUpToTextPixels() throws {
        let c = try CardRepo.comparison("meme")
        let bare = try CardRepo.render("meme", glyphs: false)
        let golden = try goldenPixels(CardRepo.goldens.appendingPathComponent("card_meme.png"))
        #expect(c.errors.isEmpty, "\(c.errors.count) pixels differ outside the text, first \(c.errors.prefix(10))")
        let textPixels = (0..<golden.count).filter { golden[$0] != bare.pixels[$0] }.count
        #expect(Double(c.differentPixels) <= 0.2 * Double(textPixels), "\(c.differentPixels) of \(textPixels)")
    }

    /// meme.json's photo is the agenda photo fixture's, uncropped, so its dithering is
    /// Differential/photo-background.png (make_card_expectations.py).
    @Test func theMemeIsOnTheAgendaPhotoFixture() throws {
        let card = try CardRepo.fixture("meme")
        let photo = PageRepo.root.appendingPathComponent("shared/layouts/agenda/background.png")
        #expect(try Data(contentsOf: CardRepo.fixtures.appendingPathComponent("background.png")) == Data(contentsOf: photo))
        #expect(card.background.image == "background.png" && card.background.crop == nil)
        let url = PageRepo.agendaFixtures.appendingPathComponent("photo.json")
        let agenda = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(agenda["background"] as? NSDictionary == ["image": "background.png", "crop": NSNull()])
    }

    // MARK: Every drawing call

    /// The background, then every string (position, anchor, size, colour, outline radius and
    /// colour, the cut and wrapped text) is the reference's, in order, for the fixtures, the
    /// Python tests' cards and random cards.
    @Test func everyDrawingCallIsTheReferences() throws {
        let cases = try CardExpectations.load().cases
        #expect(cases.count >= 60)
        for c in cases {
            let page = CardPages.card(c.card, background: c.card.background.image == nil ? nil : CardRepo.white)
            if page.operations != c.operations {
                let i = zip(page.operations, c.operations).enumerated().first { $1.0 != $1.1 }?.offset
                    ?? min(page.operations.count, c.operations.count)
                Issue.record("""
                    \(c.name): call \(i) is \(i < page.operations.count ? page.operations[i] : "missing"), \
                    expected \(i < c.operations.count ? c.operations[i] : "nothing")
                    """)
            }
        }
        let ops = cases.flatMap(\.operations)
        for marker in ["…", "outline\t15\t", "\tls\t", "\trs\t", "\tms\t", "\t12\t1\t"] {
            #expect(ops.contains { $0.contains(marker) }, "no case draws \(marker)")
        }
    }

    // MARK: test_card_layouts.py

    @Test func renderingIsDeterministic() throws {
        for name in CardRepo.names {
            #expect(try CardRepo.render(name).pixels == CardRepo.render(name).pixels)
        }
    }

    @Test(arguments: [PanelColour.white, .orange, .blue])
    func aColourBackgroundIsThatInkAllOver(colour: PanelColour) {
        #expect(Set(CardPages.card(Card(id: "a1b2c3d4", background: CardBackground(color: colour))).pixels) == [colour])
    }

    @Test(arguments: CardText.Align.allCases)
    func textIsAlignedInsideItsBox(align: CardText.Align) throws {
        let b = try #require(runs(one(size: 40, align: align)).first).bounds
        #expect(b.left >= 200 && b.right <= 600 && 120 - 4 <= b.top && b.bottom <= 360)  // glyphs may rise above the box
        let off = switch align {
        case .left: Double(b.left - 200)
        case .center: Double(b.left + b.right) / 2 - 400
        case .right: Double(b.right - 600)
        }
        #expect(abs(off) <= 4)  // the glyph's own side bearing
    }

    @Test func longTextWrapsInTheBoxAndIsCutWhenTheBoxIsTooShort() {
        let tall = runs(one(String(repeating: "字", count: 60), box: .init(x: 0.2, y: 0.1, width: 0.3, height: 0.8), size: 30))
        #expect(tall.count > 3 && !tall.last!.text.hasSuffix("…"))  // all of it, in several lines
        let short = runs(one(String(repeating: "字", count: 80), box: .init(x: 0.2, y: 0.1, width: 0.3, height: 0.2), size: 30))
        #expect(short.count == 2 && short.last!.text.hasSuffix("…"))
        for b in (tall + short).map(\.bounds) {
            #expect(160 <= b.left && b.right <= 400 && 48 - 4 <= b.top && b.bottom <= 432)  // x 160...400, y 48...432
        }
    }

    @Test func lineBreaksStartNewLines() {
        #expect(runs(one("上\n下", size: 40)).map(\.text) == ["上", "下"])
    }

    @Test func aBlankLineStaysABlankLine() {
        let r = runs(one("上\n\n上", size: 40))
        #expect(r.count == 2 && r[1].bounds.top - r[0].bounds.top == 100)  // two line pitches (1.25 * 40 each)
    }

    @Test func blankLinesAtTheEndsNeitherMoveNorCutTheText() {
        let box = CardText.Box(x: 0.25, y: 0.25, width: 0.5, height: 0.1)  // room for one line only
        let plain = runs(one("上", box: box, size: 40))
        let blank = runs(one("\u{200B}\n上\n\u{200B}", box: box, size: 40))  // zero-width spaces: cleaned away
        #expect(blank.map(\.text) == plain.map(\.text) && blank.map(\.bounds.top) == plain.map(\.bounds.top))
    }

    @Test func nothingDrawableDrawsNothing() {
        #expect(CardPages.card(one("🎂🎉")).drawnTexts.isEmpty)
        #expect(CardPages.card(one("字", box: .init(x: 0.5, y: 0.5, width: 0.01, height: 0.5), size: 240, outline: true))
                .drawnTexts.isEmpty)  // narrower than its outline
    }

    @Test func outlineDrawsInItsOwnInkAndStaysInsideTheBoxSideways() {
        let plain = CardPages.card(one("字字", background: .yellow, color: .white, size: 64))
        #expect(Set(plain.pixels) == [.yellow, .white])
        for (align, edge) in [(CardText.Align.left, 200..<260), (.right, 541..<601)] {  // the box is x 200...600
            let page = CardPages.card(one("字字", background: .yellow, color: .white, size: 64, outline: true,
                                          outlineColor: .black, align: align))
            #expect(Set(page.pixels) == [.yellow, .white, .black])
            let xs = page.pixels.indices.filter { page.pixels[$0] != .yellow }.map { $0 % PageCanvas.width }
            #expect(edge.contains(align == .left ? xs.min()! : xs.max()! + 1))
        }
    }

    /// The outline radius has no cap on a card (a calendar page on a photo caps it at 4).
    @Test func cardOutlinesFollowTheTextSize() {
        #expect([12, 23, 24, 40, 64, 130, 240].map(PageCanvas.outlineRadius(size:)) == [1, 1, 2, 3, 4, 8, 15])
        let page = CardPages.card(one("國", box: .init(x: 0, y: 0, width: 1, height: 1), size: 240, outline: true))
        #expect(page.operations.contains("outline\t15\twhite"))
    }

    @Test func theDrawnPhotoIsTheGivenOne() throws {
        let background = try PhotoPageTests.background.get()
        let card = Card(id: "a1b2c3d4", background: CardBackground(image: "x.jpg"))
        #expect(CardPages.card(card, background: background).indices == background.indices())
        #expect(Set(CardPages.card(card).pixels) == [.white])  // not given: its colour
    }

    // MARK: -

    private func one(_ text: String = "好", box: CardText.Box = .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                     background: PanelColour = .white, color: PanelColour = .black, size: Int = 48, outline: Bool = false,
                     outlineColor: PanelColour = .white, align: CardText.Align = .center) -> Card {
        Card(id: "a1b2c3d4", background: CardBackground(color: background),
             texts: [CardText(text, box: box, size: size, color: color, outline: outline, outlineColor: outlineColor,
                              align: align)])
    }

    private func runs(_ card: Card) -> [PageCanvas.TextRun] { CardPages.card(card).textRuns }
}

/// The card fixtures and goldens (shared/layouts/card/).
enum CardRepo {
    static let fixtures = PageRepo.root.appendingPathComponent("shared/layouts/card")
    static let goldens = fixtures.appendingPathComponent("golden")
    static let names = ["lines", "meme", "quote", "status"]
    static let white = try! Frame(indices: Array(repeating: PanelColour.white.index, count: PageCanvas.width * PageCanvas.height))

    static func fixture(_ name: String) throws -> Card {
        try Card.parse(Data(contentsOf: fixtures.appendingPathComponent("\(name).json")))
    }

    /// The fixture as the golden is drawn: a photo is the reference's own dithering of it.
    static func render(_ name: String, glyphs: Bool = true) throws -> PageCanvas {
        let card = try fixture(name)
        var page = PageCanvas()
        page.drawsGlyphs = glyphs
        CardPages.draw(&page, card, card.background.image == nil ? nil : try PhotoPageTests.background.get())
        return page
    }

    static func comparison(_ name: String) throws -> GoldenComparison {
        let golden = try goldenPixels(goldens.appendingPathComponent("card_\(name).png"))
        #expect(!golden.contains(nil), "the golden has colours outside the palette")
        return GoldenComparison(page: try render(name), bare: try render(name, glyphs: false), golden: golden)
    }
}

/// Differential/card-expectations.json.
struct CardExpectations: @unchecked Sendable {
    struct Case {
        let name: String
        let card: Card
        let operations: [String]
    }

    let cases: [Case]
    /// cards.json as the reference writes the four fixtures.
    let file: String

    static func load() throws -> CardExpectations {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Differential/card-expectations.json")
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(raw["cases"] as? [[String: Any]]).map { c in
            Case(name: c["name"] as! String, card: try Card.parse(object: c["card"]!), operations: c["ops"] as! [String])
        }
        return CardExpectations(cases: cases, file: try #require(raw["file"] as? String))
    }
}
