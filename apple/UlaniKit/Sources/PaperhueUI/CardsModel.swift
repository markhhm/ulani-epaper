import CoreGraphics
import Foundation
import PaperhuePages
import UlaniKit

/// 我的牌卡 (Python: CardsWindow and the App's card parts): the saved cards, each drawn as the
/// device will show it, and the card pages' choices. Putting a card on a page only saves the
/// choice: the next push (or the page's 更新這頁) sends it.
extension PushViewModel {
    /// The saved cards, newest first, as last read (`reloadCards`).
    public var savedCards: [Card] { cardShelf.cards }

    /// Read the saved cards again (after a change, or when 我的牌卡 opens) and redraw the card tiles.
    public func reloadCards() {
        do {
            cardShelf.cards = try pageSync.cards?.load() ?? []
            cardShelf.problem = nil
        } catch {
            cardShelf.cards = []
            cardShelf.problem = Problem(error)
        }
        showCards()
    }

    /// Why the cards file cannot be read, if it cannot.
    public var cardsProblem: Problem? { cardShelf.problem }

    /// `card` drawn as the device will show it (its photo dithered at the grain setting); nil
    /// until drawn: a photo takes a moment, so it is drawn off the main actor and kept.
    public func cardImage(_ card: Card) -> CGImage? {
        let key = CardShelf.Key(card: card, grain: settings.grain)
        if let drawn = cardShelf.drawings[key] { return drawn.image }
        guard let store = pageSync.cards, !cardShelf.drawing.contains(key) else { return nil }
        cardShelf.drawing.insert(key)
        Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) { () -> CardShelf.Drawn in
                let background: Frame?
                do {
                    background = try store.background(of: card, strength: key.grain)
                } catch {
                    return CardShelf.Drawn(image: nil, unreadable: true)  // not drawn without it
                }
                let frame = try? Frame(indices: CardPages.card(card, background: background).indices)
                return CardShelf.Drawn(image: frame?.previewImage(), unreadable: false)
            }.value
            guard let self else { return }
            self.cardShelf.drawing.remove(key)
            self.cardShelf.drawings[key] = drawn
            self.showCards()
        }
        return nil
    }

    /// Whether `card`'s photo could not be read when it was drawn.
    public func cardPhotoUnreadable(_ card: Card) -> Bool {
        cardShelf.drawings[CardShelf.Key(card: card, grain: settings.grain)]?.unreadable ?? false
    }

    /// The card chosen for card page `page`, if it is still saved.
    public func chosenCard(for page: Int) -> Card? {
        guard self.page(page).kind == .card, let id = settings.cardChoice[page] else { return nil }
        return savedCards.first { $0.id == id }
    }

    /// The card pages `card` is chosen for.
    public func pages(showing card: Card) -> [Int] {
        settings.cardChoice.filter { $0.value == card.id && self.page($0.key).kind == .card }.keys.sorted()
    }

    /// The card pages, in page order.
    public var cardPages: [Int] { pages.filter { $0.kind == .card }.map(\.page) }

    /// 放到第 N 頁: chooses `card` for card page `page` and shows it on the tile; nothing reaches
    /// the device until a push.
    public func chooseCard(_ card: Card, for page: Int) {
        guard canEdit, Panel.userSlots.contains(page), self.page(page).kind == .card else { return }
        settings.cardChoice[page] = card.id
        saveSettings()
        showCards()
    }

    /// With no card page yet, the page 放到… offers to turn into one: the first photo page, else
    /// page 4 (Python: App.ensure_card_page); nil when there is a card page.
    public var cardPageOffer: (page: Int, kind: PageKind)? {
        guard cardPages.isEmpty else { return nil }
        let page = pages.first { $0.kind == .photo } ?? self.page(4)
        return (page.page, page.kind)
    }

    /// 複製: a copy of `card` on top, with its own copy of the photo.
    public func duplicateCard(_ card: Card) -> Problem? {
        cardChange { _ = try $0.duplicate(card.id) }
    }

    /// 刪除: the cards and their photos; a page they were chosen for keeps no card.
    public func deleteCards(_ cards: [Card]) -> Problem? {
        let problem = cardChange { store in
            for card in cards { _ = try store.remove(card.id) }
        }
        for card in cards { cardShelf.forget(card.id) }
        guard cardsProblem == nil else { return problem }  // the file cannot be read: choices stay
        let saved = Set(savedCards.map(\.id))  // only what really went (a delete may stop halfway)
        let kept = settings.cardChoice.filter { saved.contains($0.value) }
        if kept != settings.cardChoice {
            settings.cardChoice = kept
            saveSettings()
            showCards()
        }
        return problem
    }

    /// 匯出…: `card` as a .paperhue-card file.
    public func exportCard(_ card: Card) -> Result<Data, Problem> {
        guard let store = pageSync.cards else { return .failure(.other("no card store")) }
        do {
            return .success(try store.exportCard(card.id))
        } catch {
            return .failure(Problem(error))
        }
    }

    /// 匯入…: a .paperhue-card file as a new card on top (an untrusted file: checked first).
    public func importCard(_ file: Data) -> Problem? {
        cardChange { _ = try $0.importCard(file) }
    }

    /// Saves `card` (new without an id) with `photo` as its new background, if one was chosen.
    func saveCard(_ card: Card, photo: DecodedPhoto?) -> Problem? {
        if !card.id.isEmpty { cardShelf.forget(card.id) }  // its photo may be new under the same name
        return cardChange { store in
            _ = card.id.isEmpty ? try store.add(card, photo: photo) : try store.update(card, photo: photo)
        }
    }

    private func cardChange(_ change: (CardStore) throws -> Void) -> Problem? {
        guard let store = pageSync.cards else { return .other("no card store") }
        defer { reloadCards() }
        do {
            try change(store)
            return nil
        } catch {
            return Problem(error)
        }
    }

    /// The card tiles show their chosen card as the device will.
    func showCards() {
        for page in pages where page.kind == .card {
            page.drawing = chosenCard(for: page.page).flatMap(cardImage)
        }
        cardShelf.version += 1
    }
}

/// What 我的牌卡 keeps in memory: the cards as last read and their drawings.
@MainActor @Observable
final class CardShelf {
    struct Key: Hashable, Sendable {
        let card: Card
        let grain: Double
    }

    struct Drawn: Sendable {
        let image: CGImage?
        let unreadable: Bool
    }

    var cards: [Card] = []
    var problem: Problem?
    /// Bumped whenever a drawing arrives, so views showing cards are redrawn.
    var version = 0
    @ObservationIgnored var drawings: [Key: Drawn] = [:]
    @ObservationIgnored var drawing: Set<Key> = []

    /// Drops the drawings of card `id` (changed or deleted).
    func forget(_ id: String) {
        drawings = drawings.filter { $0.key.card.id != id }
    }
}
