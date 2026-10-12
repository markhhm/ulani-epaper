import Foundation

/// An instant with the UTC offset it is written in (Python's aware `datetime`), such as
/// "2026-10-12T09:00:00+08:00": a timed event's start or end, the sync time, a note's time.
///
/// Equal, hashed and ordered by the instant alone, as Python compares aware datetimes:
/// 09:00+08:00 == 01:00Z. The offset only decides how the value is written (`iso`).
public struct OffsetDateTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The wall-clock time at `utcOffset`.
    public let wallClock: LocalDateTime
    /// Seconds east of UTC, less than a day either way.
    public let utcOffset: Int

    /// `wallClock` at `utcOffset` (Python: `datetime(..., tzinfo=timezone(timedelta(seconds=utcOffset)))`).
    public init(_ wallClock: LocalDateTime, utcOffset: Int) {
        self.wallClock = wallClock
        self.utcOffset = utcOffset
    }

    /// `instant` written in `utcOffset` (rounded to the microsecond).
    public init(_ instant: Date, utcOffset: Int) {
        let micros = LocalDateTime.epochMicroseconds(instant)
        self.init(LocalDateTime(wallMicroseconds: micros + utcOffset * 1_000_000), utcOffset: utcOffset)
    }

    /// `instant` written in `zone`'s offset at that instant (Python: `instant.astimezone(zone)`).
    public init(_ instant: Date, in zone: TimeZone) {
        self.init(instant, utcOffset: zone.secondsFromGMT(for: instant))
    }

    /// ISO 8601 with a UTC offset, as Python's `datetime.fromisoformat` reads it: "YYYY-MM-DD",
    /// "T" or a space, "HH[:MM[:SS[.fraction]]]" (a fraction beyond microseconds is cut, "," works
    /// too), then "Z" or "±HH[[:]MM[[:]SS]]". nil without an offset or for anything else.
    ///
    /// Stricter than Python 3.14, which also takes week dates, the basic format, 24:00, any
    /// separator character, a space or fraction in the offset and 60 offset minutes; nothing
    /// Paperhue reads is written that way.
    public init?(iso text: String) {
        guard let parsed = ISODateTime.parse(text), let offset = parsed.utcOffset else { return nil }
        self.init(parsed.wall, utcOffset: offset)
    }

    /// The instant.
    public var instant: Date { LocalDateTime.date(epochMicroseconds: epochMicroseconds) }

    /// The wall-clock time in `zone` (Python: `value.astimezone(zone)`).
    public func local(in zone: TimeZone) -> LocalDateTime { LocalDateTime(instant, in: zone) }

    /// The same instant written in `zone`'s offset (Python: `value.astimezone(zone)`).
    public func converted(to zone: TimeZone) -> OffsetDateTime { OffsetDateTime(instant, in: zone) }

    /// Python's `isoformat()`: "2026-10-12T09:00:00+08:00", ".ffffff" only when non-zero,
    /// "+00:00" for UTC, ":SS" on the offset only when it has seconds.
    public var iso: String { wallClock.iso + Self.offsetText(utcOffset) }

    public var description: String { iso }

    public static func == (a: OffsetDateTime, b: OffsetDateTime) -> Bool {
        a.epochMicroseconds == b.epochMicroseconds
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(epochMicroseconds) }

    public static func < (a: OffsetDateTime, b: OffsetDateTime) -> Bool {
        a.epochMicroseconds < b.epochMicroseconds
    }

    /// Microseconds since 1970 (exact, unlike a `Date`).
    var epochMicroseconds: Int { wallClock.wallMicroseconds - utcOffset * 1_000_000 }

    /// "+08:00", "-03:30", "+05:44:30".
    static func offsetText(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds), p = LocalDate.pad
        let text = "\(sign)\(p(total / 3600, 2)):\(p(total / 60 % 60, 2))"
        return total % 60 == 0 ? text : text + ":" + p(total % 60, 2)
    }
}

// MARK: - ISO 8601 text (the subset of Python's fromisoformat that Paperhue reads)

enum ISODateTime {
    /// A date-time with or without an offset; nil if it is not one (see `OffsetDateTime(iso:)`).
    static func parse(_ text: String) -> (wall: LocalDateTime, utcOffset: Int?)? {
        let b = Array(text.utf8)
        guard b.count >= 13, b[10] == UInt8(ascii: "T") || b[10] == UInt8(ascii: " "),
              let date = LocalDate(iso: String(decoding: b[0..<10], as: UTF8.self)) else { return nil }
        var i = 11
        guard let hour = twoDigits(b, i) else { return nil }
        i += 2
        var minute = 0, second = 0, microsecond = 0
        if i < b.count, b[i] == colon {
            guard let m = twoDigits(b, i + 1) else { return nil }
            minute = m
            i += 3
            if i < b.count, b[i] == colon {
                guard let s = twoDigits(b, i + 1) else { return nil }
                second = s
                i += 3
                if i < b.count, b[i] == UInt8(ascii: ".") || b[i] == UInt8(ascii: ",") {
                    var j = i + 1, digits = 0
                    while j < b.count, let d = LocalDate.digits(b[j...j]) {
                        if digits < 6 {
                            microsecond = microsecond * 10 + d
                            digits += 1
                        }
                        j += 1
                    }
                    guard j > i + 1 else { return nil }
                    for _ in digits..<6 { microsecond *= 10 }
                    i = j
                }
            }
        }
        guard let wall = LocalDateTime(date: date, hour: hour, minute: minute, second: second,
                                       microsecond: microsecond) else { return nil }
        if i == b.count { return (wall, nil) }
        guard let offset = offsetSeconds(b[i...]) else { return nil }
        return (wall, offset)
    }

    /// "Z", or "±HH", "±HH:MM", "±HHMM", "±HH:MM:SS", "±HHMMSS" (each field in range) -> seconds east of UTC.
    static func offsetSeconds(_ text: ArraySlice<UInt8>) -> Int? {
        let b = Array(text)
        if b == [UInt8(ascii: "Z")] { return 0 }
        guard let sign = b.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") else { return nil }
        var fields: [Int] = []
        var i = 1
        let separated = b.count > 3 && b[3] == colon
        while i < b.count {
            if !fields.isEmpty, separated {
                guard b[i] == colon else { return nil }
                i += 1
            }
            guard fields.count < 3, let value = twoDigits(b, i) else { return nil }
            fields.append(value)
            i += 2
        }
        guard !fields.isEmpty, fields[0] <= 23, fields.dropFirst().allSatisfy({ $0 <= 59 }) else { return nil }
        let seconds = fields[0] * 3600 + (fields.count > 1 ? fields[1] * 60 : 0) + (fields.count > 2 ? fields[2] : 0)
        return sign == UInt8(ascii: "-") ? -seconds : seconds
    }

    /// Two ASCII digits at `i`, or nil.
    private static func twoDigits(_ b: [UInt8], _ i: Int) -> Int? {
        i + 2 <= b.count ? LocalDate.digits(b[i..<(i + 2)]) : nil
    }

    private static let colon = UInt8(ascii: ":")
}
