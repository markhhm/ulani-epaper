import Foundation
import PaperhueAgenda
import PaperhuePages
import Testing
import UlaniKit
@testable import PaperhueUI

// 我的牌卡 and the card editor (Python: CardsWindow, CardEditor, App.choose_card): putting a card on
// a card page only saves the choice; a push sends it.

@MainActor
@Suite final class CardsModelTests {
    let keepAwake = FakeKeepAwake()
    let defaults = TestDefaults(pages: [1: .card, 2: .photo, 3: .photo, 4: .month])
    let folder: URL

    init() throws {
        folder = try temporaryDirectory()
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    var store: CardStore { CardStore(folder: folder) }

    func makeModel(_ service: FakePushService = FakePushService()) -> PushViewModel {
        let sync = PageSync(notes: NoteStore(url: folder.appendingPathComponent("notes.json")),
                            backgrounds: BackgroundStore(folder: folder.appendingPathComponent("backgrounds")),
                            cards: store, secrets: MemoryFeedSecrets(), loader: TableLoader())
        return PushViewModel(service: service, keepAwake: keepAwake, defaults: defaults.defaults,
                             preferredLanguages: ["zh-Hant-TW"], pageSync: sync, agent: FakeAgent())
    }

    func saved(_ text: String = "生日快樂", colour: PanelColour = .yellow) throws -> Card {
        try store.add(Card(background: CardBackground(color: colour),
                           texts: [CardText(text, box: CardText.Box(x: 0.1, y: 0.3, width: 0.8, height: 0.4), size: 72)]))
    }

    /// Waits until `condition` holds (drawings arrive off the main actor), at most a few seconds.
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aCardPutOnACardPageIsShownAndPushedOnlyWhenPushed() async throws {
        let card = try saved()
        let service = FakePushService()
        let model = makeModel(service)
        #expect(model.savedCards == [card] && model.cardPages == [1])
        #expect(!model.canPush(page: model.page(1)))  // no card chosen yet
        #expect(model.tileText(model.page(1)).hasPrefix("牌卡頁"))

        model.chooseCard(card, for: 1)
        #expect(try PageSettings.load(from: defaults.reopened()).cardChoice == [1: card.id])
        #expect(model.pages(showing: card) == [1])
        await waitUntil { model.page(1).drawing != nil }
        #expect(model.page(1).drawing != nil)
        #expect(await service.pushed.isEmpty)

        await model.push(page: 1)
        #expect(await service.pushed == [[1: try Frame(indices: CardPages.card(card).indices)]])
    }

    @Test func withoutACardPageTheFirstPhotoPageIsOffered() throws {
        defaults.defaults.removeObject(forKey: PageSettings.defaultsKey)
        try PageSettings(pages: [1: .month, 2: .photo, 3: .photo, 4: .todo]).save(to: defaults.defaults)
        let model = makeModel()
        #expect(model.cardPageOffer?.page == 2 && model.cardPageOffer?.kind == .photo)
        #expect(model.strings.cardPageAsk(page: 2, kind: .photo)
                == "還沒有任何一頁設為牌卡。要把第 2 頁（照片）改成牌卡頁並把牌卡放上去嗎？")
        model.setKind(.card, for: 2)
        #expect(model.cardPageOffer == nil && model.cardPages == [2])
    }

    @Test func deletingACardOrChangingThePageDropsTheChoice() throws {
        let card = try saved(), other = try saved("出門了", colour: .blue)
        let model = makeModel()
        model.chooseCard(card, for: 1)
        #expect(model.deleteCards([card]) == nil)
        #expect(model.savedCards == [other] && model.settings.cardChoice.isEmpty)
        model.chooseCard(other, for: 1)
        model.setKind(.photo, for: 1)
        #expect(model.settings.cardChoice.isEmpty)
    }

    @Test func duplicateExportAndImport() throws {
        let card = try saved()
        let model = makeModel()
        #expect(model.duplicateCard(card) == nil && model.savedCards.count == 2)
        guard case .success(let file) = model.exportCard(card) else {
            Issue.record("not exported")
            return
        }
        #expect(model.importCard(file) == nil && model.savedCards.count == 3)
        #expect(model.savedCards[0].texts == card.texts && model.savedCards[0].id != card.id)
        if case .card = model.importCard(Data("not a zip".utf8)) {} else { Issue.record("a bad file was taken") }
        #expect(model.savedCards.count == 3)
    }

    @Test func theEditorMakesAndChecksACard() throws {
        let model = makeModel()
        let editor = CardEditorModel(card: nil, model: model)
        editor.setColour(.blue)
        editor.addText("文字")
        #expect(editor.box?.color == .white && editor.box?.outlineColor == .black)  // white on a dark colour
        editor.setText("  ")
        #expect(!editor.save() && editor.status == .textEmpty(1))
        editor.setText("歡迎回家")
        editor.setSize(500)
        #expect(editor.box?.size == 240)
        editor.setInk(.yellow)
        #expect(editor.box?.outlineColor == .black)
        #expect(editor.save() && model.savedCards.count == 1)
        #expect(model.savedCards[0].background.color == .blue && model.savedCards[0].texts[0].text == "歡迎回家")
        for _ in 0..<8 { editor.addText("x") }
        #expect(editor.texts.count == 8 && editor.status == .textsFull)
    }

    @Test func boxesStayOnTheScreen() {
        let box = CardText.Box(x: 0.1, y: 0.1, width: 0.5, height: 0.3)
        #expect(CardEditorModel.move(box, dx: 0.9, dy: -1) == CardText.Box(x: 0.5, y: 0, width: 0.5, height: 0.3))
        let grown = CardEditorModel.resize(box, corner: .se, x: 2, y: 0.2)
        #expect(grown.x == 0.1 && grown.width == 0.9 && abs(grown.height - 0.1) < 1e-12)
        let flipped = CardEditorModel.resize(box, corner: .nw, x: 0.9, y: 0.9)  // past the opposite corner
        #expect(abs(flipped.width - CardEditorModel.minimumBox) < 1e-12 && abs(flipped.height - CardEditorModel.minimumBox) < 1e-12)
    }
}
