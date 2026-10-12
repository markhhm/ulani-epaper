import Foundation

// The message board's notes (留言板), as in python/src/ulani_epaper/notes.py: short messages
// the owner writes for the device. They are the owner's own words, so unlike calendar data
// they may be stored (NoteStore).

/// The colours a note can have, in the order the app offers them (Python: `NOTE_COLOURS`).
public enum NoteColour: String, CaseIterable, Sendable {
    case yellow, orange, green, blue, red
}

/// One note. Fields as in notes.json; a note read from a page fixture is not validated, so
/// `text` and `color` may be anything there (the pages fall back to yellow).
public struct Note: Hashable, Sendable, Identifiable {
    /// 8 lower-case hex characters, unique within the file.
    public let id: String
    /// Normalized (`Note.normalize`): NFC, "\n" line breaks, no outer whitespace.
    public let text: String
    /// When it was written, as stored: ISO 8601 with a UTC offset, "2026-10-12T14:03:00+08:00".
    public let at: String
    /// One of `Note.colours`.
    public let color: String
    /// `at` parsed; nil if it is not ISO 8601 with a UTC offset (`OffsetDateTime(iso:)`).
    public let written: OffsetDateTime?

    public init(id: String, text: String, at: String, color: String = Note.defaultColour) {
        self.id = id
        self.text = text
        self.at = at
        self.color = color
        self.written = OffsetDateTime(iso: at)
    }

    /// When it was written, on the wall clock in `zone` (Python: `layouts._note_time`): a time
    /// without an offset is taken as it is written; nil if `at` is not a date-time.
    public func time(in zone: TimeZone) -> LocalDateTime? {
        guard let parsed = ISODateTime.parse(at) else { return nil }
        guard let offset = parsed.utcOffset else { return parsed.wall }
        return OffsetDateTime(parsed.wall, utcOffset: offset).local(in: zone)
    }

    // MARK: Limits and text rules

    /// Python: `NOTE_COLOURS`.
    public static let colours = NoteColour.allCases.map(\.rawValue)
    public static let defaultColour = NoteColour.yellow.rawValue
    /// Characters (Unicode code points, as Python counts them) after `normalize`.
    public static let maxText = 300
    public static let maxLines = 8

    /// The text as it is stored: composed (NFC), "\n" line breaks, stripped of outer
    /// whitespace (Python's `str.strip()`). Its code point count is what counts against `maxText`.
    public static func normalize(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        let composed = text.precomposedStringWithCanonicalMapping.unicodeScalars
        var i = composed.startIndex
        while i != composed.endIndex {
            let scalar = composed[i]
            i = composed.index(after: i)
            if scalar == "\r" {
                if i != composed.endIndex, composed[i] == "\n" { i = composed.index(after: i) }
                scalars.append("\n")
            } else {
                scalars.append(scalar)
            }
        }
        return strip(scalars)
    }

    /// Python's `str.strip()`: without the outer whitespace (`isPythonSpace`).
    static func strip(_ scalars: some BidirectionalCollection<Unicode.Scalar>) -> String {
        let first = scalars.firstIndex { !isPythonSpace($0) } ?? scalars.endIndex
        let end = scalars.lastIndex { !isPythonSpace($0) }.map(scalars.index(after:)) ?? first
        return String(String.UnicodeScalarView(scalars[first..<end]))
    }

    /// `normalize(text)`, or throws the `NoteError` why it cannot be a note (Python: `check_text`).
    public static func checkText(_ text: String) throws -> String {
        let text = normalize(text)
        let count = text.unicodeScalars.count
        if count == 0 { throw NoteError.empty }
        if count > maxText { throw NoteError.tooLong(count: count) }
        if text.unicodeScalars.filter({ $0 == "\n" }).count + 1 > maxLines { throw NoteError.tooManyLines }
        return text
    }

    /// Throws `NoteError.unknownColour` unless `color` is one of `colours` (Python: `_check_colour`).
    public static func checkColour(_ color: String) throws {
        guard colours.contains(color) else { throw NoteError.unknownColour(color) }
    }

    /// Python's `str.isspace()`: Unicode White_Space plus the C0 separators U+001C...U+001F.
    static func isPythonSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            true
        default:
            false
        }
    }
}
