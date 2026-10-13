import Foundation
import UlaniKit

/// Why a card, the cards file or a `.paperhue-card` file was refused. `description` is the Python
/// reference's text (Traditional Chinese for what the owner made, English for the files);
/// `message(inChinese:)` gives every case in either language for the app to choose. A value
/// received from a file is quoted as Python's `repr()` quotes it.
public enum CardError: Error, Equatable, Sendable {
    /// Which colour of a card.
    public enum Ink: String, Sendable {
        case text, outline, background

        var chinese: String {
            switch self {
            case .text: "文字顏色"
            case .outline: "外框顏色"
            case .background: "背景顏色"
            }
        }
    }

    // The card (Python: `check`)
    /// More than `Card.maxTexts` text boxes; `count` is how many.
    case tooManyTexts(count: Int)
    /// A text is empty after `Note.normalize`.
    case emptyText
    /// More than `CardText.maxText` characters; `count` is how many.
    case textTooLong(count: Int)
    /// A text in a file is not a string.
    case textNotString
    /// A text box's position is not 4 finite numbers.
    case boxNotNumbers(String)
    /// A text box reaches outside the screen, or has no size.
    case boxOutside(String)
    /// The size is not an integer in `CardText.sizes`.
    case badSize(String)
    /// `outline` in a file is not true or false.
    case outlineNotBool
    /// Not one of `CardText.Align`.
    case unknownAlign(String)
    /// Not one of the 7 panel colours.
    case unknownColour(Ink, String)
    /// The background image is not a plain .jpg or .png file name.
    case badImageName(String)
    /// The crop is not 4 finite numbers.
    case cropNotNumbers(String)
    /// The crop reaches outside the photo, or has no size.
    case cropOutside(String)

    // The card's JSON (Python: `parse`)
    /// Not a card at all: not a JSON object, a field missing or of the wrong kind.
    case notACard(String)
    case unknownVersion(String)
    /// The id is not 8 lower-case hex characters.
    case badID(String)

    // The store (Python: `load`, `get`, `add`, `update`, `remove`, `export_card`)
    /// The cards file exists but cannot be read, or is not JSON. It is left as it is.
    case unreadableFile(path: String, reason: String)
    /// The cards file is JSON but not a valid cards file. It is left as it is.
    case invalidFile(path: String, reason: String)
    /// The cards file or a background cannot be written.
    case cannotSave(path: String, reason: String)
    /// No saved card has this id.
    case noSuchCard(String)
    /// The card names a background photo it was not given (`CardStore.add`, `update`).
    case photoRequired
    /// The background photo cannot be read (not an image, over 50 MP, gone).
    case unreadablePhoto(String)
    /// The crop does not suit the background photo.
    case crop(CropError)
    /// `exportCard`: the card's background file is gone.
    case missingPhoto(path: String)

    // The .paperhue-card file (Python: `import_card`)
    /// Not a card file: why. Nothing was saved.
    indirect case notACardFile(CardError)
    /// Not a zip, or one that cannot be read (damaged, encrypted, an unknown compression).
    case damagedFile(String)
    /// The file has no entry of this name.
    case missingEntry(String)
    /// The entry is over its limit (`CardStore.maxJSONBytes`, `maxImageBytes`).
    case entryTooBig(String)

    public func message(inChinese zh: Bool) -> String {
        switch self {
        case .tooManyTexts(let count):
            zh ? "每張牌卡最多 \(Card.maxTexts) 個文字框（目前 \(count) 個）"
                : "A card can have at most \(Card.maxTexts) text boxes (this one has \(count))"
        case .emptyText:
            zh ? "文字框是空的" : "A text box is empty"
        case .textTooLong(let count):
            zh ? "每個文字框最多 \(CardText.maxText) 字（目前 \(count) 字）"
                : "A text box can have at most \(CardText.maxText) characters (this one has \(count))"
        case .textNotString:
            zh ? "文字必須是字串" : "The text must be a string"
        case .boxNotNumbers(let value):
            zh ? "文字框的位置要有 4 個數字，收到 \(value)"
                : "The text box position must be 4 numbers, not \(value)"
        case .boxOutside(let value):
            zh ? "文字框必須在畫面內（0 到 1 的比例），收到 \(value)"
                : "The text box must lie inside the screen (fractions 0 to 1), not \(value)"
        case .badSize(let value):
            zh ? "字級必須是 \(CardText.sizes.lowerBound) 到 \(CardText.sizes.upperBound) 的整數，收到 \(value)"
                : "The size must be a whole number from \(CardText.sizes.lowerBound) to \(CardText.sizes.upperBound), "
                    + "not \(value)"
        case .outlineNotBool:
            zh ? "outline 必須是 true 或 false" : "outline must be true or false"
        case .unknownAlign(let value):
            zh ? "對齊必須是 \(Self.aligns) 之一，收到 \(value)"
                : "The alignment must be one of \(Self.aligns), not \(value)"
        case .unknownColour(let ink, let value):
            zh ? "\(ink.chinese)必須是 \(Self.inks) 之一，收到 \(value)"
                : "The \(ink.rawValue) colour must be one of \(Self.inks), not \(value)"
        case .badImageName(let value):
            zh ? "背景圖必須是單純的檔名（jpg 或 png），收到 \(value)"
                : "The background image must be a plain file name (jpg or png), not \(value)"
        case .cropNotNumbers(let value):
            zh ? "裁切範圍要有 4 個數字，收到 \(value)" : "The crop must be 4 numbers, not \(value)"
        case .cropOutside(let value):
            zh ? "裁切範圍必須在畫面內（0 到 1 的比例），收到 \(value)"
                : "The crop must lie inside the photo (fractions 0 to 1), not \(value)"
        case .notACard(let reason):
            zh ? "這不是牌卡：\(reason)" : "not a card: \(reason)"
        case .unknownVersion(let value):
            zh ? "不認得的牌卡版本 \(value)" : "unknown version \(value)"
        case .badID(let value):
            zh ? "牌卡代碼是 8 個十六進位字元，收到 \(value)" : "card ids are 8 hex characters, got \(value)"
        case .unreadableFile(let path, let reason):
            zh ? "無法讀取牌卡檔 \(path)：\(reason)" : "cannot read the cards file \(path): \(reason)"
        case .invalidFile(let path, let reason):
            zh ? "牌卡檔 \(path) 的內容不正確：\(reason)" : "the cards file \(path) is invalid: \(reason)"
        case .cannotSave(let path, let reason):
            zh ? "無法儲存 \(path)：\(reason)" : "cannot save \(path): \(reason)"
        case .noSuchCard(let id):
            zh ? "沒有這張牌卡：\(id)" : "No such card: \(id)"
        case .photoRequired:
            zh ? "牌卡的背景圖要用 photo 指定" : "A card's background photo must be given as photo"
        case .unreadablePhoto(let reason):
            zh ? "無法讀取背景圖：\(reason)" : "Cannot read the background photo: \(reason)"
        case .crop(let error):
            zh ? "裁切範圍不適合這張背景圖：\(error)" : "The crop does not suit the background photo: \(error)"
        case .missingPhoto(let path):
            zh ? "找不到牌卡的背景圖：\(path)" : "The card's background photo is missing: \(path)"
        case .notACardFile(let reason):
            zh ? "這不是有效的牌卡檔：\(reason.message(inChinese: true))"
                : "This is not a valid card file: \(reason.message(inChinese: false))"
        case .damagedFile(let reason):
            zh ? "檔案損壞或不是 zip（\(reason)）" : "The file is damaged or not a zip (\(reason))"
        case .missingEntry(let name):
            zh ? "檔案裡沒有 \(name)" : "There is no \(name) in the file"
        case .entryTooBig(let name):
            zh ? "\(name) 太大" : "\(name) is too big"
        }
    }

    /// Whether the Python reference words this case in Chinese.
    var pythonSaysItInChinese: Bool {
        switch self {
        case .notACard, .unknownVersion, .badID, .unreadableFile, .invalidFile, .cannotSave, .crop, .damagedFile,
             .missingEntry:
            false
        default:
            true
        }
    }

    private static let inks = PanelColour.allCases.map(\.rawValue).joined(separator: ", ")
    private static let aligns = CardText.Align.allCases.map(\.rawValue).joined(separator: ", ")
}

extension CardError: CustomStringConvertible, LocalizedError {
    /// The Python reference's text.
    public var description: String { message(inChinese: pythonSaysItInChinese) }

    /// The app's language: Traditional Chinese.
    public var errorDescription: String? { message(inChinese: true) }
}
