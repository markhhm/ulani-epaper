import CoreGraphics
import Foundation
import Observation
import PaperhueAgenda
import PaperhuePages
import UlaniKit

/// One card being made or changed (Python: CardEditor): a background (one of the 7 colours, or a
/// photo with its crop) and up to 8 text boxes, previewed as the device will show it. A photo is
/// dithered once per photo, crop or grain, not on every change. Saving checks the card and keeps
/// it (a newly chosen photo is copied into the store then).
@MainActor @Observable
public final class CardEditorModel: Identifiable {
    public let id = UUID()
    /// "" for a new card.
    let cardID: String
    public private(set) var colour: PanelColour
    /// The photo behind the card: the saved one, or one chosen now (`newPhoto`).
    public private(set) var photo: DecodedPhoto?
    /// The saved photo's file name, while the card keeps it.
    private var savedImage: String?
    private var newPhoto = false
    public private(set) var crop: Crop?
    public private(set) var texts: [CardText]
    /// The selected box.
    public private(set) var current: Int?
    /// The preview: the card in the device's 7 colours.
    public private(set) var preview: CGImage?
    /// What the last action did or why it could not (shown under the preview).
    public private(set) var status: Status = .none
    /// The photo cut and dithered for the preview; nil until ready.
    @ObservationIgnored private var background: Frame?
    @ObservationIgnored private var backgroundGeneration = 0

    public enum Status: Equatable, Sendable {
        case none, makingPreview, previewReady, problem(Problem), textsFull
        /// Saving refused: text box `n` (1-based) is empty, or too long.
        case textEmpty(Int), textTooLong(Int, count: Int)
        case saveFailed(Problem)
    }

    @ObservationIgnored private weak var model: PushViewModel?

    /// The smallest side of a text box (Python: gui_model.MIN_BOX).
    static let minimumBox = 0.05

    init(card: Card?, model: PushViewModel) {
        self.model = model
        cardID = card?.id ?? ""
        colour = card?.background.color ?? .white
        crop = card?.background.crop
        texts = card?.texts ?? []
        current = (card?.texts.isEmpty ?? true) ? nil : 0
        savedImage = card?.background.image
        if let card, card.background.image != nil {
            photo = try? model.pageSync.cards?.photo(of: card)
            loadBackground()
        }
        redraw()
    }

    public var isNew: Bool { cardID.isEmpty }
    public var hasPhoto: Bool { photo != nil }
    public var box: CardText? { current.map { texts[$0] } }

    /// The card as it is now (unchecked: the preview shows what is there; `save` checks it).
    var card: Card {
        let background = photo != nil
            ? CardBackground(image: newPhoto ? nil : savedImage, crop: crop)
            : CardBackground(color: colour)
        return Card(id: cardID, background: background, texts: texts)
    }

    // MARK: text boxes

    /// 新增文字框: a box in the middle third, white on a photo or a dark colour, else black.
    public func addText(_ text: String) {
        guard texts.count < Card.maxTexts else {
            status = .textsFull
            return
        }
        let ink: PanelColour = photo != nil || [.black, .blue, .red].contains(colour) ? .white : .black
        let top = 0.1 + 0.15 * Double(texts.count % 5)
        texts.append(CardText(text, box: CardText.Box(x: 0.1, y: top, width: 0.8, height: 0.25), size: 64, color: ink,
                              outline: photo != nil, outlineColor: Self.outline(for: ink)))
        current = texts.count - 1
        redraw()
    }

    public func select(_ index: Int?) {
        current = index
    }

    public func deleteText() {
        guard let current else { return }
        texts.remove(at: current)
        self.current = texts.isEmpty ? nil : texts.count - 1
        redraw()
    }

    public func setText(_ text: String) { change { $0.text = text } }

    /// Moves the selected box by `dx`, `dy` (fractions of the screen), staying on it.
    public func move(dx: Double, dy: Double, preview: Bool = true) {
        change(preview: preview) { $0.box = Self.move($0.box, dx: dx, dy: dy) }
    }

    /// Drags `corner` of the selected box to `x`, `y` (fractions of the screen).
    public func dragCorner(_ corner: Corner, x: Double, y: Double, preview: Bool = true) {
        change(preview: preview) { $0.box = Self.resize($0.box, corner: corner, x: x, y: y) }
    }

    public func setSize(_ size: Int) {
        change { $0.size = min(max(size, CardText.sizes.lowerBound), CardText.sizes.upperBound) }
    }

    /// The text colour; the outline takes the colour that stands out against it.
    public func setInk(_ ink: PanelColour) {
        change {
            $0.color = ink
            $0.outlineColor = Self.outline(for: ink)
        }
    }

    public func setOutline(_ on: Bool) { change { $0.outline = on } }
    public func setAlign(_ align: CardText.Align) { change { $0.align = align } }

    /// The preview again after a drag (drags do not redraw the card on every step).
    public func finishDrag() { redraw() }

    private func change(preview: Bool = true, _ edit: (inout CardText) -> Void) {
        guard let current else { return }
        edit(&texts[current])
        if preview { redraw() }
    }

    // MARK: background

    /// A plain background in one of the 7 colours, instead of a photo.
    public func setColour(_ colour: PanelColour) {
        self.colour = colour
        photo = nil
        savedImage = nil
        newPhoto = false
        crop = nil
        background = nil
        backgroundGeneration += 1
        redraw()
    }

    /// 照片…: the photo from `source` (refused over 50 MP or unreadable, nothing changes then).
    public func choosePhoto(_ source: PhotoSource) {
        status = .makingPreview
        backgroundGeneration += 1
        let generation = backgroundGeneration
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () async throws -> DecodedPhoto in
                try await source.fetch().decode()
            }.result
            guard let self, self.backgroundGeneration == generation else { return }
            switch result {
            case .success(let decoded):
                self.photo = decoded
                self.newPhoto = true
                self.crop = nil
                self.loadBackground()
            case .failure(let error):
                self.status = .problem(Problem(error))
            }
        }
    }

    /// 調整範圍…: the photo and its crop for the crop editor; nil without a photo.
    public var cropEditing: CropEditing? {
        guard let photo else { return nil }
        var editing = CropEditing(page: 0, image: photo.image, geometry: CropGeometry(photo: photo.size, crop: crop))
        editing.onConfirm = { [weak self] crop in self?.setCrop(crop) }
        return editing
    }

    public func setCrop(_ crop: Crop?) {
        guard let photo else { return }
        if let crop, (try? crop.validated(width: photo.size.width, height: photo.size.height)) == nil { return }
        self.crop = crop
        loadBackground()
    }

    /// Cuts and dithers the photo off the main actor; the text shows on white meanwhile.
    private func loadBackground() {
        guard let photo else { return }
        backgroundGeneration += 1
        background = nil
        status = .makingPreview
        let generation = backgroundGeneration, crop = crop, strength = model?.settings.grain ?? 1
        Task { [weak self] in
            let frame = await Task.detached(priority: .userInitiated) { () -> Frame? in
                let checked = try? crop.map { try $0.validated(width: photo.size.width, height: photo.size.height) }
                return FrameEncoder.encode(photo.image, fit: .cover, crop: checked ?? nil, dither: true,
                                           strength: strength)
            }.value
            guard let self, self.backgroundGeneration == generation else { return }
            self.background = frame
            self.status = .previewReady
            self.redraw()
        }
        redraw()
    }

    // MARK: preview and saving

    /// The live preview: the card in the 7 colours as the device will show it (a photo card shows
    /// its text on white until the photo is dithered).
    func redraw() {
        let white = photo != nil && background == nil ? PageCanvas().indices : nil
        let background = self.background ?? white.flatMap { try? Frame(indices: $0) }
        let frame = try? Frame(indices: CardPages.card(card, background: background).indices)
        preview = frame?.previewImage()
    }

    /// 儲存: checks and keeps the card; false, with the reason shown, when it cannot be saved.
    public func save() -> Bool {
        guard let model else { return false }
        for (n, box) in texts.enumerated() {  // which box, as Windows says it
            let count = Note.normalize(box.text).unicodeScalars.count
            if count == 0 {
                status = .textEmpty(n + 1)
                return false
            }
            if count > CardText.maxText {
                status = .textTooLong(n + 1, count: count)
                return false
            }
        }
        if let problem = model.saveCard(card, photo: newPhoto ? photo : nil) {
            status = .saveFailed(problem)
            return false
        }
        return true
    }

    /// A dithered photo still on its way is not wanted any more.
    public func close() {
        backgroundGeneration += 1
    }

    // MARK: box geometry (Python: gui_model.move_box, resize_box)

    public enum Corner: String, CaseIterable, Sendable { case nw, ne, sw, se }

    /// Moved by `dx`, `dy`, staying on the screen.
    static func move(_ box: CardText.Box, dx: Double, dy: Double) -> CardText.Box {
        CardText.Box(x: min(max(box.x + dx, 0), 1 - box.width), y: min(max(box.y + dy, 0), 1 - box.height),
                     width: box.width, height: box.height)
    }

    /// `corner` dragged to `x`, `y`: the opposite corner stays, the box stays on the screen and
    /// at least `minimumBox` on each side.
    static func resize(_ box: CardText.Box, corner: Corner, x: Double, y: Double) -> CardText.Box {
        let east = corner == .ne || corner == .se, south = corner == .sw || corner == .se
        let anchorX = east ? box.x : box.x + box.width, anchorY = south ? box.y : box.y + box.height
        let x = east ? max(min(x, 1), anchorX + minimumBox) : min(max(x, 0), anchorX - minimumBox)
        let y = south ? max(min(y, 1), anchorY + minimumBox) : min(max(y, 0), anchorY - minimumBox)
        return CardText.Box(x: min(x, anchorX), y: min(y, anchorY), width: abs(x - anchorX), height: abs(y - anchorY))
    }

    /// Light inks get a black outline, dark ones a white one (Python: LIGHT_INKS).
    static func outline(for ink: PanelColour) -> PanelColour {
        [.white, .yellow, .green, .orange].contains(ink) ? .black : .white
    }
}
