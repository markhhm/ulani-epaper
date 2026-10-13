import Foundation

/// The data is not an iCalendar file (Python: `ical.ICalError`). `reason` names what was wrong
/// in general terms; it never quotes the data.
public struct ICalError: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public var description: String { "not an iCalendar file (\(reason))" }
}

/// One content line: `NAME;PARAM=value:value`.
public struct ICalProperty: Sendable {
    /// Upper-cased.
    public let name: String
    /// Upper-cased names; each value list as written (`MEMBER="a","b"` is two values), quotes
    /// and escapes removed.
    public let parameters: [String: [String]]
    /// The value as written (backslash escapes kept).
    public let raw: String
    /// DTSTART, DTEND, DUE, RECURRENCE-ID, DURATION, RDATE and EXDATE, decoded (an RDATE or
    /// EXDATE line can list several); empty for any other property.
    public let values: [ICalValue]
    /// One of those whose value could not be read. icalendar lets that pass only inside a
    /// VEVENT (ical.py then skips the event); anywhere else the file is not read.
    public let isBroken: Bool

    public var value: ICalValue? { values.first }

    /// TEXT with `\n` `\N` `\,` `\;` `\:` `\\` resolved. X- properties keep the raw value, as
    /// icalendar keeps unknown properties verbatim (`X-WR-CALNAME:a\, b` stays so).
    public var text: String { name.hasPrefix("X-") ? raw : ICalLines.unescape(raw) }

    /// A parameter's value (a list joined by commas), any case.
    public func parameter(_ name: String) -> String? {
        parameters[name.uppercased()]?.joined(separator: ",")
    }
}

/// A component (VCALENDAR, VEVENT, VTODO, VTIMEZONE, ...): its properties and the components
/// inside it, in file order.
public struct ICalComponent: Sendable {
    /// Upper-cased.
    public let name: String
    public internal(set) var properties: [ICalProperty] = []
    public internal(set) var components: [ICalComponent] = []

    /// Every property `name` (any case), in order.
    public func all(_ name: String) -> [ICalProperty] {
        let key = name.uppercased()
        return properties.filter { $0.name == key }
    }

    /// The first property `name` (what ical.py reads when a property is repeated).
    public func first(_ name: String) -> ICalProperty? {
        let key = name.uppercased()
        return properties.first { $0.name == key }
    }

    public func contains(_ name: String) -> Bool { first(name) != nil }

    /// This component and every one inside it, depth first in file order (icalendar's
    /// `walk`), those named `name` (any case) or all.
    public func walk(_ name: String? = nil) -> [ICalComponent] {
        let found = name == nil || self.name == name!.uppercased() ? [self] : []
        return found + components.flatMap { $0.walk(name) }
    }
}

public enum ICalendar {
    /// Reads iCalendar data as the Python reference does (`icalendar.use_zoneinfo()`,
    /// `Calendar.from_ical`, then ical.py's VCALENDAR check) and returns the VCALENDAR.
    ///
    /// UTF-8 (a byte order mark and invalid bytes are tolerated), lines ending in CRLF or LF,
    /// folds removed. Time zones are resolved per file (`ZoneResolver`). A line or value that
    /// cannot be read is skipped inside a VEVENT and fails the file anywhere else, as in
    /// icalendar. Throws `ICalError`.
    public static func read(_ data: Data) throws -> ICalComponent {
        let lines = ICalLines.unfold(String(decoding: data, as: UTF8.self))
        let zones = ZoneResolver()
        var top = try readComponents(lines, zones)
        if zoneFollowsOtherComponents(top) {
            // icalendar reads the file again: the zones are known by then
            top = try readComponents(lines, zones)
        }
        guard top.count == 1 else { throw ICalError(reason: top.isEmpty ? "no component" : "several components") }
        guard top[0].name == "VCALENDAR" else { throw ICalError(reason: "no VCALENDAR") }
        return top[0]
    }

    /// The date/time properties a TZID parameter applies to.
    private static let zoned: Set = ["DTSTART", "DTEND", "DUE", "RECURRENCE-ID", "RDATE", "EXDATE"]

    private static func readComponents(_ lines: [String], _ zones: ZoneResolver) throws -> [ICalComponent] {
        var stack: [ICalComponent] = []
        var top: [ICalComponent] = []
        for line in lines {
            guard let (name, parameters, raw) = ICalLines.split(line) else {
                guard stack.last?.name == "VEVENT" else { throw ICalError(reason: "a line that is not NAME:VALUE") }
                continue
            }
            switch name {
            case "BEGIN":
                stack.append(ICalComponent(name: ICalLines.unescape(raw).uppercased()))
            case "END":
                guard let done = stack.popLast() else { throw ICalError(reason: "END without BEGIN") }
                if stack.isEmpty {
                    top.append(done)
                } else {
                    stack[stack.count - 1].components.append(done)
                }
                if ICalLines.unescape(raw).uppercased() == "VTIMEZONE" && done.contains("TZID") {
                    try zones.define(done)
                }
            default:
                guard !stack.isEmpty else {
                    if name == "X-COMMENT" { continue }  // icalendar allows it after the end
                    throw ICalError(reason: "a property outside any component")
                }
                let tolerant = stack[stack.count - 1].name == "VEVENT"
                if let p = try property(name, parameters, raw, zones, tolerant: tolerant) {
                    stack[stack.count - 1].properties.append(p)
                }
            }
        }
        return top
    }

    private static func property(_ name: String, _ parameters: [String: [String]], _ raw: String,
                                 _ zones: ZoneResolver, tolerant: Bool) throws -> ICalProperty? {
        var values: [ICalValue] = []
        var broken = false
        if name == "DURATION" || zoned.contains(name) {
            let text = ICalLines.unescape(raw)
            if name == "RDATE" && text.isEmpty { return nil }  // icalendar ignores an empty RDATE
            let tzid = zoned.contains(name) ? parameters["TZID"]?.joined(separator: ",") ?? "" : ""
            let zone = tzid.isEmpty ? nil : zones.zone(tzid)
            let items = name == "RDATE" || name == "EXDATE"
                ? text.split(separator: ",", omittingEmptySubsequences: false).map(String.init) : [text]
            do {
                values = try items.map { try ICalValue.parse($0, zone: zone) }
            } catch {
                guard tolerant else { throw ICalError(reason: "an unreadable \(name)") }
                (values, broken) = ([], true)
            }
        }
        return ICalProperty(name: name, parameters: parameters, raw: raw, values: values, isBroken: broken)
    }

    /// A VTIMEZONE after any other component inside a calendar makes icalendar read the file
    /// again (a TZID may refer to a zone defined further down).
    private static func zoneFollowsOtherComponents(_ top: [ICalComponent]) -> Bool {
        var onlyZones = true
        for c in top {
            for sub in c.components {
                if sub.name != "VTIMEZONE" {
                    onlyZones = false
                } else if !onlyZones {
                    return true
                }
            }
        }
        return false
    }
}

/// Content lines as icalendar splits them (parser.content_line, not strict).
enum ICalLines {
    /// The lines with folds removed: split at LF (one CR before it dropped), empty lines
    /// dropped, a line starting with a space or tab joined to the one before without that
    /// character. A leading byte order mark is dropped.
    static func unfold(_ text: String) -> [String] {
        var lines: [String.UnicodeScalarView] = []
        var scalars = Substring(text).unicodeScalars
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        for var line in scalars.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.last == "\r" { line.removeLast() }
            guard let first = line.first else { continue }
            if (first == " " || first == "\t") && !lines.isEmpty {
                lines[lines.count - 1].append(contentsOf: line.dropFirst())
            } else {
                lines.append(String.UnicodeScalarView(line))
            }
        }
        return lines.map(String.init)
    }

    /// Name (upper-cased), parameters and raw value, or nil for a line that is not
    /// `NAME[;PARAM=value...]:value` (icalendar's `Contentline.raw_parts`).
    static func split(_ line: String) -> (String, [String: [String]], String)? {
        let s = Array(line.unicodeScalars)
        var nameEnd: Int?, colon: Int?
        var quoted = false, escaped = false
        for (i, c) in s.enumerated() {
            if c == "\"" && !escaped {
                quoted.toggle()
            } else if c == "\\" && !quoted {
                escaped = true
                continue
            } else if !quoted && !escaped {
                if (c == ":" || c == ";") && nameEnd == nil { nameEnd = i }
                if c == ":" && colon == nil { colon = i }
            }
            escaped = false
        }
        let valueSplit = colon == nil || colon == 0 ? s.count : colon!
        guard let nameEnd, nameEnd > 0, nameEnd + 1 != valueSplit else { return nil }
        let name = String(String.UnicodeScalarView(s[..<nameEnd].filter { $0 != " " && $0 != "\t" }))
        guard isToken(name.unicodeScalars),
              let parameters = parameters(Array(s[min(nameEnd + 1, valueSplit)..<valueSplit])) else { return nil }
        let value = valueSplit < s.count ? String(String.UnicodeScalarView(s[(valueSplit + 1)...])) : ""
        return (name.uppercased(), parameters, value)
    }

    /// `PARAM=value;PARAM="quoted","list"` as `Parameters.from_ical` reads it after icalendar's
    /// clean-up: spaces around `;` and `=` dropped, `\,` `\;` `\:` `\\` taken literally, RFC 6868
    /// `^n` `^'` `^^` resolved. nil where icalendar raises.
    private static func parameters(_ s: [Unicode.Scalar]) -> [String: [String]]? {
        var chars: [Char] = []
        var i = 0
        while i < s.count {
            let escaped = s[i] == "\\" && i + 1 < s.count && ",;:\\".unicodeScalars.contains(s[i + 1])
            chars.append(Char(c: s[escaped ? i + 1 : i], literal: escaped))
            i += escaped ? 2 : 1
        }
        guard !chars.isEmpty else { return [:] }
        var result: [String: [String]] = [:]
        for item in splitOutsideQuotes(chars, at: ";") {
            guard let eq = splitOutsideQuotes(item, at: "=").first?.count, eq < item.count else { return nil }
            let key = String(String.UnicodeScalarView(trimmed(item[..<eq]).map(\.c)))
            guard isToken(key.unicodeScalars) else { return nil }
            let value = trimmed(item[(eq + 1)...])
            var values: [String] = []
            for v in value.isEmpty ? [] : splitOutsideQuotes(value, at: ",") {
                let quoted = v.first?.c == "\"" && v.last?.c == "\""
                let inner = quoted ? Array(v.drop { $0.c == "\"" }.reversed().drop { $0.c == "\"" }.reversed()) : v
                guard !inner.contains(where: { !$0.literal && $0.isForbidden(quoted: quoted) }) else { return nil }
                values.append(rfc6868(inner.map(\.c)))
            }
            result[key.uppercased()] = values.isEmpty ? [""] : values
        }
        return result
    }

    /// A parameter character, and whether it was escaped with a backslash.
    private struct Char {
        let c: Unicode.Scalar
        let literal: Bool

        /// Control characters and `"`, and in an unquoted value `,` `;` `:` (validate_param_value).
        func isForbidden(quoted: Bool) -> Bool {
            c.value <= 8 || (10...31).contains(c.value) || c.value == 127 || c == "\""
                || (!quoted && (c == "," || c == ";" || c == ":"))
        }
    }

    /// Parts between unquoted, unescaped `sep`s.
    private static func splitOutsideQuotes(_ s: [Char], at sep: Unicode.Scalar) -> [[Char]] {
        var parts: [[Char]] = [[]]
        var quoted = false
        for x in s {
            if x.c == "\"" && !x.literal { quoted.toggle() }
            if x.c == sep && !x.literal && !quoted {
                parts.append([])
            } else {
                parts[parts.count - 1].append(x)
            }
        }
        return parts
    }

    private static func trimmed(_ s: ArraySlice<Char>) -> [Char] {
        let space: (Char) -> Bool = { ($0.c == " " || $0.c == "\t") && !$0.literal }
        return Array(s.drop(while: space).reversed().drop(while: space).reversed())
    }

    private static func rfc6868(_ s: [Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            if s[i] == "^", i + 1 < s.count, let r: Unicode.Scalar = ["^": "^", "n": "\n", "'": "\""][s[i + 1]] {
                out.append(r)
                i += 2
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return String(out)
    }

    /// icalendar's `validate_token`: letters, digits, `_`, `.` and `-`.
    private static func isToken(_ s: some Collection<Unicode.Scalar>) -> Bool {
        !s.isEmpty && s.allSatisfy {
            $0.properties.isAlphabetic || $0.properties.numericType != nil || "_.-".unicodeScalars.contains($0)
        }
    }

    /// TEXT escapes: `\\` `\,` `\;` `\:` give the character, `\n` and `\N` a line feed; any
    /// other backslash stays.
    static func unescape(_ raw: String) -> String {
        guard raw.unicodeScalars.contains("\\") else { return raw }
        var out = String.UnicodeScalarView()
        var it = raw.unicodeScalars.makeIterator()
        var pending = it.next()
        while let c = pending {
            pending = it.next()
            guard c == "\\", let next = pending, "\\,;:nN".unicodeScalars.contains(next) else {
                out.append(c)
                continue
            }
            out.append(next == "n" || next == "N" ? "\n" : next)
            pending = it.next()
        }
        return String(out)
    }
}
