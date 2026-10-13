import Foundation
import PaperhueAgenda
import UlaniKit

/// A card (牌卡, shared/CARDS.md; Python: `cards.Card`): a background, a photo with a crop or one
/// of the panel's 7 colours, and up to 8 short text boxes, drawn by `CardPages.card`. The owner's
/// own words and pictures, kept by `CardStore` and traded between apps as `.paperhue-card` files.
public struct Card: Hashable, Sendable, Identifiable {
    public static let version = 1
    /// Text boxes per card.
    public static let maxTexts = 8

    /// 8 lower-case hex characters, unique among the saved cards ("" until `CardStore.add`).
    public var id: String
    public var background: CardBackground
    /// Drawn in this order, later ones on top.
    public var texts: [CardText]

    public init(id: String = "", background: CardBackground = CardBackground(), texts: [CardText] = []) {
        self.id = id
        self.background = background
        self.texts = texts
    }
}

/// What fills the screen behind a card's text (Python: `cards.Background`).
public struct CardBackground: Hashable, Sendable {
    /// Fills the screen when there is no image.
    public var color: PanelColour
    /// A plain file name in the store's backgrounds folder (`[0-9A-Za-z_-]{1,40}` and .jpg,
    /// .jpeg or .png), never a path.
    public var image: String?
    /// The part of the photo that fills the screen (shared/CROP.md); nil: the centred one.
    public var crop: Crop?

    public init(color: PanelColour = .white, image: String? = nil, crop: Crop? = nil) {
        self.color = color
        self.image = image
        self.crop = crop
    }
}

/// One text box of a card (Python: `cards.TextBox`): bold text wrapped inside the box from its top.
public struct CardText: Hashable, Sendable {
    /// Characters (code points, as Python counts them) after `Note.normalize`.
    public static let maxText = 80
    /// Font sizes in panel pixels (the panel is 480 high).
    public static let sizes = 12...240

    public enum Align: String, CaseIterable, Sendable {
        case left, center, right
    }

    /// x, y, width, height as fractions of the 800 x 480 screen.
    public struct Box: Hashable, Sendable, CustomStringConvertible {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// `(x, y, width, height)`, like Python's tuple.
        public var description: String { "(\(x), \(y), \(width), \(height))" }
    }

    /// "\n" is a line break.
    public var text: String
    public var box: Box
    public var size: Int
    public var color: PanelColour
    /// Draws the text with an outline in `outlineColor` (white text outlined black reads on a photo).
    public var outline: Bool
    public var outlineColor: PanelColour
    public var align: Align

    public init(_ text: String, box: Box, size: Int = 48, color: PanelColour = .black, outline: Bool = false,
                outlineColor: PanelColour = .white, align: Align = .center) {
        self.text = text
        self.box = box
        self.size = size
        self.color = color
        self.outline = outline
        self.outlineColor = outlineColor
        self.align = align
    }
}

// MARK: Validation

extension Card {
    /// The card with its texts normalized (`Note.normalize`), or the `CardError` why it cannot be
    /// a card (Python: `cards.check`). Its background image is only a file name here; `CardStore`
    /// looks at the file.
    public func checked() throws -> Card {
        try Self.checkImage(background.image)
        try background.crop.map(Self.checkCrop)
        try Self.checkCount(texts.count)
        var card = self
        for (i, t) in texts.enumerated() {
            card.texts[i].text = try Self.checkText(t.text)
            try Self.checkBox(t.box)
            try Self.checkSize(t.size)
        }
        return card
    }

    static func checkImage(_ name: String?) throws {
        let plain = /[0-9A-Za-z_\-]{1,40}\.(jpg|jpeg|png)/.matchingSemantics(.unicodeScalar)  // by code point, as `re`
        if let name, name.wholeMatch(of: plain) == nil { throw CardError.badImageName(pythonRepr(name)) }
    }

    static func checkCrop(_ crop: Crop) throws {
        let values = [crop.left, crop.top, crop.width, crop.height]
        guard values.allSatisfy(\.isFinite) else { throw CardError.cropNotNumbers(crop.description) }
        guard inside(values) else { throw CardError.cropOutside(crop.description) }
    }

    static func checkCount(_ count: Int) throws {
        if count > maxTexts { throw CardError.tooManyTexts(count: count) }
    }

    static func checkText(_ text: String) throws -> String {
        let text = Note.normalize(text)
        let count = text.unicodeScalars.count
        if count == 0 { throw CardError.emptyText }
        if count > CardText.maxText { throw CardError.textTooLong(count: count) }
        return text
    }

    static func checkBox(_ box: CardText.Box) throws {
        let values = [box.x, box.y, box.width, box.height]
        guard values.allSatisfy(\.isFinite) else { throw CardError.boxNotNumbers(box.description) }
        guard inside(values) else { throw CardError.boxOutside(box.description) }
    }

    static func checkSize(_ size: Int) throws {
        if !CardText.sizes.contains(size) { throw CardError.badSize(String(size)) }
    }

    /// 0 <= left, 0 <= top, width > 0, height > 0, right and bottom at most 1 (1e-9 slack).
    private static func inside(_ v: [Double]) -> Bool {
        v[0] >= 0 && v[1] >= 0 && v[2] > 0 && v[3] > 0 && v[0] + v[2] <= 1 + 1e-9 && v[1] + v[3] <= 1 + 1e-9
    }

    /// 8 characters of 0-9 a-f.
    static func isID(_ id: String) -> Bool {
        let b = Array(id.utf8)
        return b.count == 8 && b.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

// MARK: JSON

extension Card {
    /// The card's JSON (shared/CARDS.md) as Python writes it (`json.dumps(to_json(card),
    /// ensure_ascii=False, indent=1)`): a background with an image has no colour, one without
    /// has no crop.
    public var json: String { PythonJSON.dumps(pythonJSON) }

    /// A card from its JSON, checked (Python: `cards.parse`); throws `CardError`. Missing optional
    /// fields take their defaults; the rules are tested in Python's order, so the error is the one
    /// it reports.
    public static func parse(_ data: Data) throws -> Card {
        let raw: Any
        do {
            raw = try PythonJSON.parse(data)
        } catch {
            throw CardError.notACard("not JSON")
        }
        return try parse(object: raw)
    }

    /// Python: `cards.to_json`.
    var pythonJSON: PythonJSON.Value {
        typealias M = PythonJSON.Value.Member
        func numbers(_ v: [Double]) -> PythonJSON.Value { .array(v.map { .double($0) }) }
        let background: PythonJSON.Value = if let image = background.image {
            .object([M("image", .string(image)), M("crop", background.crop.map {
                numbers([$0.left, $0.top, $0.width, $0.height])
            } ?? .null)])
        } else {
            .object([M("color", .string(background.color.rawValue))])
        }
        let texts: [PythonJSON.Value] = texts.map { t in
            .object([M("text", .string(t.text)), M("box", numbers([t.box.x, t.box.y, t.box.width, t.box.height])),
                     M("size", .int(t.size)), M("color", .string(t.color.rawValue)), M("outline", .bool(t.outline)),
                     M("outline_color", .string(t.outlineColor.rawValue)), M("align", .string(t.align.rawValue))])
        }
        return .object([M("version", .int(Self.version)), M("id", .string(id)), M("background", background),
                        M("texts", .array(texts))])
    }

    /// A parsed card JSON, checked (the body of Python's `parse`).
    static func parse(object raw: Any) throws -> Card {
        guard let obj = raw as? [String: Any] else { throw CardError.notACard("not a JSON object") }
        func field(_ object: [String: Any], _ key: String) throws -> Any {
            guard let value = object[key] else { throw CardError.notACard("KeyError(\(pythonRepr(key)))") }
            return value
        }
        let version = try field(obj, "version")
        guard (version as? NSNumber)?.doubleValue == Double(Self.version) else {
            throw CardError.unknownVersion(repr(version))
        }
        guard let bg = try field(obj, "background") as? [String: Any] else {
            throw CardError.notACard("the background is not an object")
        }
        let image = bg["image"].flatMap { $0 is NSNull ? nil : $0 }
        let crop = try bg["crop"].flatMap { $0 is NSNull ? nil : $0 }.map { value in
            guard let list = value as? [Any] else { throw CardError.notACard("the crop is not a list") }
            return list
        }
        guard let items = try field(obj, "texts") as? [Any] else { throw CardError.notACard("the texts are not a list") }
        let texts = try items.map { item in
            guard let t = item as? [String: Any] else { throw CardError.notACard("a text box is not an object") }
            let text = try field(t, "text")
            guard let box = try field(t, "box") as? [Any] else { throw CardError.notACard("a text box's box is not a list") }
            return (text, box, t)
        }
        let id = try field(obj, "id")
        guard let id = PythonJSON.string(id), isID(id) else { throw CardError.badID(repr(id)) }

        // Python's check()
        if let image, PythonJSON.string(image) == nil { throw CardError.badImageName(repr(image)) }
        let name = image.flatMap(PythonJSON.string)
        try checkImage(name)
        let cut = try crop.map { list in
            let v = try numbers(list) { CardError.cropNotNumbers($0) }
            let c = Crop(left: v[0], top: v[1], width: v[2], height: v[3])
            try checkCrop(c)
            return c
        }
        let colour = try ink(bg["color"] ?? "white") { CardError.unknownColour(.background, $0) }
        try checkCount(texts.count)
        return Card(id: id, background: CardBackground(color: colour, image: name, crop: cut),
                    texts: try texts.map { try text($0.0, $0.1, $0.2) })
    }

    /// One text box: its text, its box and the whole object (Python: `_check_text`).
    private static func text(_ raw: Any, _ list: [Any], _ t: [String: Any]) throws -> CardText {
        guard let raw = PythonJSON.string(raw) else { throw CardError.textNotString }
        let text = try checkText(raw)
        let v = try numbers(list) { CardError.boxNotNumbers($0) }
        let box = CardText.Box(x: v[0], y: v[1], width: v[2], height: v[3])
        try checkBox(box)
        let size = t["size"] ?? 48
        guard let n = size as? NSNumber, !PythonJSON.isBool(n), !CFNumberIsFloatType(n), let s = Int(exactly: n.doubleValue),
              CardText.sizes.contains(s) else {
            throw CardError.badSize(repr(size))
        }
        let outline = t["outline"] ?? false
        guard PythonJSON.isBool(outline), let flag = outline as? Bool else { throw CardError.outlineNotBool }
        let align = t["align"] ?? "center"
        guard let a = PythonJSON.string(align).flatMap(CardText.Align.init) else { throw CardError.unknownAlign(repr(align)) }
        return CardText(text, box: box, size: s,
                        color: try ink(t["color"] ?? "black") { CardError.unknownColour(.text, $0) }, outline: flag,
                        outlineColor: try ink(t["outline_color"] ?? "white") { CardError.unknownColour(.outline, $0) },
                        align: a)
    }

    /// Four finite numbers (not booleans), as doubles (Python: `_numbers`).
    private static func numbers(_ list: [Any], _ error: (String) -> CardError) throws -> [Double] {
        let values = list.compactMap { v in (v as? NSNumber).flatMap { PythonJSON.isBool($0) ? nil : $0.doubleValue } }
        guard list.count == 4, values.count == 4, values.allSatisfy(\.isFinite) else {
            throw error("(" + list.map(repr).joined(separator: ", ") + (list.count == 1 ? ",)" : ")"))
        }
        return values
    }

    /// One of the panel's colours by name (Python: `_ink`).
    private static func ink(_ value: Any, _ error: (String) -> CardError) throws -> PanelColour {
        guard let colour = PythonJSON.string(value).flatMap(PanelColour.init) else { throw error(repr(value)) }
        return colour
    }

    /// Python's `repr()` of a parsed JSON value, for the error messages.
    static func repr(_ value: Any) -> String {
        switch value {
        case is NSNull: "None"
        case let n as NSNumber where PythonJSON.isBool(n): n.boolValue ? "True" : "False"
        case let n as NSNumber: CFNumberIsFloatType(n) ? n.doubleValue.description : n.stringValue
        case let s as String: pythonRepr(s)
        case let list as [Any]: "[" + list.map(repr).joined(separator: ", ") + "]"
        case let object as [String: Any]:
            "{" + object.sorted { $0.key < $1.key }.map { pythonRepr($0.key) + ": " + repr($0.value) }
                .joined(separator: ", ") + "}"
        default: "\(value)"
        }
    }
}
