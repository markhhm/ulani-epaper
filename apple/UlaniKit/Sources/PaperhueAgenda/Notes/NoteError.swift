import Foundation

/// Why a note or the notes file was refused. `description` is the Python reference's text
/// (Traditional Chinese for what the owner typed, English for the file); `message(inChinese:)`
/// gives every case in either language for the app to choose.
public enum NoteError: Error, Equatable, Sendable {
    /// The text is empty after `Note.normalize`.
    case empty
    /// More than `Note.maxText` characters; `count` is how many.
    case tooLong(count: Int)
    /// More than `Note.maxLines` lines.
    case tooManyLines
    /// Not one of `Note.colours`.
    case unknownColour(String)
    /// The notes file exists but cannot be read, or is not JSON. It is left as it is.
    case unreadableFile(path: String, reason: String)
    /// The notes file is JSON but not a valid notes file. It is left as it is.
    case invalidFile(path: String, reason: String)
    /// Notes that cannot be saved as they are (Python: `save()`'s ValueError); English.
    case invalidNotes(String)
    /// The notes file cannot be written.
    case cannotSave(path: String, reason: String)
    /// `remove` found neither that id nor that position among `count` notes.
    case noSuchNote(key: String, count: Int)
    /// `remove` with no notes at all.
    case noNotes

    public func message(inChinese: Bool) -> String {
        switch self {
        case .empty:
            inChinese ? "留言是空的" : "The note is empty"
        case .tooLong(let count):
            inChinese ? "留言最多 \(Note.maxText) 字（目前 \(count) 字）"
                : "A note can have at most \(Note.maxText) characters (this one has \(count))"
        case .tooManyLines:
            inChinese ? "留言最多 \(Note.maxLines) 行" : "A note can have at most \(Note.maxLines) lines"
        case .unknownColour(let colour):
            inChinese ? "留言的顏色必須是 \(Note.colours.joined(separator: ", ")) 之一，收到 \(pythonRepr(colour))"
                : "The note colour must be one of \(Note.colours.joined(separator: ", ")), not \(pythonRepr(colour))"
        case .unreadableFile(let path, let reason):
            inChinese ? "無法讀取留言檔 \(path)：\(reason)" : "cannot read the notes file \(path): \(reason)"
        case .invalidFile(let path, let reason):
            inChinese ? "留言檔 \(path) 的內容不正確：\(reason)" : "the notes file \(path) is invalid: \(reason)"
        case .invalidNotes(let reason):
            inChinese ? "留言資料不正確：\(reason)" : reason
        case .cannotSave(let path, let reason):
            inChinese ? "無法儲存留言檔 \(path)：\(reason)" : "cannot save the notes file \(path): \(reason)"
        case .noSuchNote(let key, let count):
            inChinese ? "沒有這則留言：\(key)（請用留言的代碼，或 1 到 \(count) 的編號）"
                : "No such note: \(key) (use the note's code, or a number from 1 to \(count))"
        case .noNotes:
            inChinese ? "目前沒有留言" : "There are no notes"
        }
    }

    /// Whether the Python reference words this case in Chinese.
    var pythonSaysItInChinese: Bool {
        switch self {
        case .empty, .tooLong, .tooManyLines, .unknownColour, .noSuchNote, .noNotes: true
        case .unreadableFile, .invalidFile, .invalidNotes, .cannotSave: false
        }
    }
}

extension NoteError: CustomStringConvertible, LocalizedError {
    /// The Python reference's text.
    public var description: String { message(inChinese: pythonSaysItInChinese) }

    /// The app's language: Traditional Chinese.
    public var errorDescription: String? { message(inChinese: true) }
}

/// Python's `repr()` of a string: single quotes unless the text has one and no double quote;
/// backslashes, quotes and unprintable characters escaped.
func pythonRepr(_ s: String) -> String {
    let quote: Unicode.Scalar = s.contains("'") && !s.contains("\"") ? "\"" : "'"
    var out = String(quote)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case quote: out += "\\" + String(quote)
        case _ where !isPythonPrintable(scalar):
            let hex = String(scalar.value, radix: 16)
            let width = scalar.value < 0x100 ? 2 : scalar.value < 0x10000 ? 4 : 8
            out += (width == 2 ? "\\x" : width == 4 ? "\\u" : "\\U")
                + String(repeating: "0", count: width - hex.count) + hex
        default: out.unicodeScalars.append(scalar)
        }
    }
    out.unicodeScalars.append(quote)
    return out
}

/// Python's `str.isprintable()` for one character: not Cc, Cf, Cs, Co, Cn, Zl, Zp, and no
/// space separator other than " ".
private func isPythonPrintable(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == " " { return true }
    switch scalar.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator,
         .spaceSeparator:
        return false
    default:
        return true
    }
}
