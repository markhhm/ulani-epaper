import Foundation
import ImageIO
import PaperhueAgenda
import UlaniKit
import UniformTypeIdentifiers

/// The saved cards (python/src/ulani_epaper/cards.py, shared/CARDS.md "Stored files"), in the
/// folder the app chooses, laid out as the Python reference lays out its config folder:
///
///     cards.json      {"version": 1, "cards": [card, ...]}, newest first, written atomically
///     backgrounds/    <id>.jpg for each card with a photo, upright and at most 4K
///
/// The cards file is written exactly as the Python reference writes it; one that cannot be read
/// or is invalid is reported and never overwritten. Cards and their photos never leave the Mac
/// except as `.paperhue-card` files (`exportCard`, `importCard`). Every method throws `CardError`.
public struct CardStore: Sendable {
    /// What a `.paperhue-card` file may hold (it is not trusted).
    public static let maxJSONBytes = 64 * 1024
    public static let maxImageBytes = 40 * 1024 * 1024
    public static let fileExtension = "paperhue-card"

    public let folder: URL
    private let token: @Sendable () -> String

    /// `token` draws an id candidate, 8 lower-case hex characters (Python: `secrets.token_hex(4)`);
    /// tests inject their own.
    public init(folder: URL, token: @escaping @Sendable () -> String = NoteStore.randomToken) {
        self.folder = folder
        self.token = token
    }

    /// cards.json.
    public var url: URL { folder.appendingPathComponent("cards.json") }
    /// The background photos, `<id>.jpg`.
    var backgrounds: BackgroundStore { BackgroundStore(folder: folder.appendingPathComponent("backgrounds")) }

    // MARK: Cards

    /// The cards, newest first. A missing file means no cards.
    public func load() throws -> [Card] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw CardError.unreadableFile(path: url.path, reason: error.localizedDescription)
        }
        // Python reads the file as strict UTF-8 and json.loads refuses a byte order mark.
        guard String(data: data, encoding: .utf8) != nil, !data.starts(with: [0xEF, 0xBB, 0xBF]),
              let raw = try? PythonJSON.parse(data) else {
            throw CardError.unreadableFile(path: url.path, reason: "not UTF-8 JSON")
        }
        do {
            guard let object = raw as? [String: Any] else { throw CardError.notACard("not a JSON object") }
            guard (object["version"] as? NSNumber)?.doubleValue == Double(Card.version) else {
                throw CardError.unknownVersion(Card.repr(object["version"] ?? NSNull()))
            }
            guard let items = object["cards"] as? [Any] else { throw CardError.notACard("no list of cards") }
            let cards = try items.map(Card.parse(object:))
            if Set(cards.map(\.id)).count != cards.count { throw CardError.notACard("duplicate card ids") }
            return cards
        } catch let error as CardError {
            throw CardError.invalidFile(path: url.path, reason: error.description)
        }
    }

    /// The saved card `id`.
    public func get(_ id: String) throws -> Card {
        guard let card = try load().first(where: { $0.id == id }) else { throw CardError.noSuchCard(id) }
        return card
    }

    /// Saves `card` on top under a new id (the one it has is ignored) and returns it as saved.
    /// `photo` becomes its background, kept as `<id>.jpg`; its `background.crop` then applies to
    /// that photo. Without one the card has its colour (a background image must be given here).
    @discardableResult
    public func add(_ card: Card, photo: DecodedPhoto? = nil) throws -> Card {
        let cards = try load()
        var card = card
        card.id = newID(cards)
        let prepared: URL?
        (card, prepared) = try withPhoto(try card.checked(), photo, current: nil)
        try saveThenInstall([card] + cards, prepared, as: card)
        return card
    }

    /// Replaces the saved card with the same id, in its place. Without `photo` the background
    /// image must be the one the card already has, or none: then its file is deleted.
    @discardableResult
    public func update(_ card: Card, photo: DecodedPhoto? = nil) throws -> Card {
        var cards = try load()
        guard let i = cards.firstIndex(where: { $0.id == card.id }) else { throw CardError.noSuchCard(card.id) }
        let old = cards[i]
        let prepared: URL?
        (cards[i], prepared) = try withPhoto(try card.checked(), photo, current: old)
        try saveThenInstall(cards, prepared, as: cards[i])
        if let image = old.background.image, cards[i].background.image == nil {
            backgrounds.remove(PageBackground(image: image))
        }
        return cards[i]
    }

    /// Deletes a card and its background photo; returns the card.
    @discardableResult
    public func remove(_ id: String) throws -> Card {
        var cards = try load()
        guard let i = cards.firstIndex(where: { $0.id == id }) else { throw CardError.noSuchCard(id) }
        let card = cards.remove(at: i)
        try save(cards)
        if let image = card.background.image { backgrounds.remove(PageBackground(image: image)) }
        return card
    }

    /// Saves a copy of card `id` on top, under a new id and with its own copy of the photo.
    @discardableResult
    public func duplicate(_ id: String) throws -> Card {
        let cards = try load()
        guard var card = cards.first(where: { $0.id == id }) else { throw CardError.noSuchCard(id) }
        card.id = newID(cards)
        if let image = card.background.image {
            let source = backgrounds.url(PageBackground(image: image))
            let copy = PageBackground(image: "\(card.id).jpg")
            try? FileManager.default.removeItem(at: backgrounds.url(copy))  // left by a save that failed
            do {
                try FileManager.default.copyItem(at: source, to: backgrounds.url(copy))
            } catch {
                throw CardError.missingPhoto(path: source.path)
            }
            card.background.image = copy.image
        }
        try save([card] + cards)
        return card
    }

    // MARK: Photos

    /// The card's background as the panel shows it, for `CardPages.card`: the crop of its photo
    /// filling the screen, dithered at `strength` (the grain setting); nil for a colour.
    public func background(of card: Card, strength: Double) throws -> Frame? {
        guard let image = card.background.image else { return nil }
        do {
            return try backgrounds.frame(PageBackground(image: image, crop: card.background.crop), strength: strength)
        } catch {
            throw CardError.unreadablePhoto("\(image): \(error)")
        }
    }

    /// The card's photo as kept (for the crop editor), with the size its crop refers to; nil for a colour.
    public func photo(of card: Card) throws -> DecodedPhoto? {
        guard let image = card.background.image else { return nil }
        do {
            return try backgrounds.photo(PageBackground(image: image))
        } catch {
            throw CardError.unreadablePhoto("\(image): \(error)")
        }
    }

    // MARK: .paperhue-card

    /// Card `id` as a `.paperhue-card` file: a zip of card.json and, when it has a photo,
    /// background.jpg (Python: `export_card`).
    public func exportCard(_ id: String) throws -> Data {
        var card = try get(id)
        var photo: [(name: String, data: Data, deflate: Bool)] = []
        if let image = card.background.image {
            let url = backgrounds.url(PageBackground(image: image))
            do {
                photo = [(Self.exportedImage, try Data(contentsOf: url), false)]  // a JPEG does not shrink
            } catch {
                throw CardError.missingPhoto(path: url.path)
            }
            card.background.image = Self.exportedImage
        }
        return try CardZip.write([("card.json", Data(card.json.utf8), true)] + photo)
    }

    /// Adds the card in a `.paperhue-card` file as a new card (a new id, so importing twice makes
    /// two), its photo taken through the photo rules (`FrameEncoder.loadPhoto`); returns it as
    /// saved. `CardError.notACardFile` says why a file is refused; nothing is saved then. Read a
    /// file `.mappedIfSafe`: only its entries are read.
    @discardableResult
    public func importCard(_ file: Data) throws -> Card {
        let card: Card, photo: DecodedPhoto?
        do {
            let zip = try CardZip(file)
            card = try Card.parse(try zip.read("card.json", limit: Self.maxJSONBytes))
            photo = try card.background.image.map { name in
                let data = try zip.read(name, limit: Self.maxImageBytes)
                // An untrusted file: only the JPEG or PNG every app writes reaches a decoder.
                let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
                guard type == UTType.jpeg.identifier || type == UTType.png.identifier else {
                    throw CardError.unreadablePhoto("\(name): not a JPEG or PNG image")
                }
                do {
                    return try FrameEncoder.loadPhoto(data: data)
                } catch {
                    throw CardError.unreadablePhoto("\(error)")
                }
            }
        } catch let error as CardError {
            throw CardError.notACardFile(error)
        }
        do {
            return try add(card, photo: photo)
        } catch let error as CardError {
            guard case .crop = error else { throw error }
            throw CardError.notACardFile(error)
        }
    }

    // MARK: -

    /// The background's name inside a `.paperhue-card` file.
    static let exportedImage = "background.jpg"

    /// Writes `cards` (newest first, each checked) atomically, creating the folder if needed.
    func save(_ cards: [Card]) throws {
        let text = PythonJSON.dumps(.object([.init("version", .int(Card.version)),
                                             .init("cards", .array(cards.map(\.pythonJSON)))]))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw CardError.cannotSave(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Saves `cards`, then puts a newly prepared photo in place as `card`'s, so a failed save
    /// leaves neither a stray photo nor a photo the saved crop does not fit.
    private func saveThenInstall(_ cards: [Card], _ prepared: URL?, as card: Card) throws {
        do {
            try save(cards)
        } catch {
            prepared.map(backgrounds.discard)
            throw error
        }
        guard let prepared, let image = card.background.image else { return }
        let kept = PageBackground(image: image)
        do {
            try backgrounds.install(prepared, as: kept)
        } catch {
            backgrounds.discard(prepared)
            throw CardError.cannotSave(path: backgrounds.url(kept).path, reason: error.localizedDescription)
        }
    }

    /// An id no card in `cards` has.
    private func newID(_ cards: [Card]) -> String {
        let taken = Set(cards.map(\.id))
        var id = token()
        while taken.contains(id) { id = token() }
        return id
    }

    /// `card` (checked) with its background: `photo` to be kept as `<id>.jpg` (prepared in a
    /// temporary file, installed once the cards are saved), or the file the card already has. The
    /// crop is checked against the photo (Python: `_with_photo`).
    private func withPhoto(_ card: Card, _ photo: DecodedPhoto?, current: Card?) throws -> (Card, URL?) {
        var card = card
        let crop = card.background.crop
        if let photo {
            let size = photo.size
            do {
                try crop?.validated(width: size.width, height: size.height)
            } catch {
                throw CardError.crop(error)
            }
            let kept = PageBackground(image: "\(card.id).jpg")
            let prepared: URL
            do {
                prepared = try backgrounds.prepare(photo.image)
            } catch {
                throw CardError.cannotSave(path: backgrounds.url(kept).path, reason: error.localizedDescription)
            }
            card.background = CardBackground(image: kept.image, crop: crop)
            return (card, prepared)
        }
        guard let image = card.background.image else {
            card.background.crop = nil  // a crop means nothing without a photo
            return (card, nil)
        }
        guard current?.background.image == image else { throw CardError.photoRequired }
        if let crop, let size = try self.photo(of: card)?.size {
            do {
                try crop.validated(width: size.width, height: size.height)
            } catch {
                throw CardError.crop(error)
            }
        }
        return (card, nil)
    }
}
