import Foundation

/// A decoded date/time property value, as icalendar's `vDDDTypes` decodes it.
public enum ICalValue: Equatable, Sendable {
    case date(LocalDate)
    case dateTime(ICalDateTime)
    /// Whole seconds; negative for `-P...` (Python's `timedelta`).
    case duration(Int)
    /// `start/end` or `start/duration` (`RDATE;VALUE=PERIOD`); the reference does not use these.
    case period

    /// Reads one value by its form, whatever VALUE= says: `P`/`-P`/`+P` a duration, `/` a
    /// period, 15 or 16 characters a date-time, 8 a date. `zone` is the TZID's zone when it
    /// was found: a date-time then takes it (whatever follows the seconds), and so does a
    /// date, as midnight. Without one, a date-time ending in `Z` is UTC and one with nothing
    /// after the seconds is floating (an unknown TZID gives floating times, as in Python).
    static func parse(_ text: String, zone: ICalZone?) throws -> ICalValue {
        let s = Array(text.unicodeScalars)
        let upper = text.uppercased()
        if upper.hasPrefix("P") || upper.hasPrefix("-P") || upper.hasPrefix("+P") {
            return .duration(try duration(text))
        }
        if text.contains("/") {
            let halves = text.split(separator: "/", omittingEmptySubsequences: false)
            guard halves.count == 2 else { throw ValueError() }
            _ = try halves.map { try parse(String($0), zone: zone) }
            return .period
        }
        switch s.count {
        case 15, 16:
            guard s[8] == "T", let date = date(s[0..<8]), let hour = number(s[9..<11]),
                  let minute = number(s[11..<13]), let second = number(s[13..<15]),
                  let wall = LocalDateTime(date: date, hour: hour, minute: minute, second: second) else {
                throw ValueError()
            }
            if let zone { return .dateTime(ICalDateTime(wall: wall, zone: zone)) }
            switch String(String.UnicodeScalarView(s[15...])) {
            case "": return .dateTime(ICalDateTime(wall: wall, zone: nil))
            case "Z": return .dateTime(ICalDateTime(wall: wall, zone: .utc))
            default: throw ValueError()
            }
        case 8:
            guard let date = date(s[...]) else { throw ValueError() }
            if let zone { return .dateTime(ICalDateTime(wall: LocalDateTime(midnightOf: date), zone: zone)) }
            return .date(date)
        default:
            throw ValueError()  // a TIME (6 or 7 characters) is no use to an event either
        }
    }

    /// `[+-]P[nW][nD][T[nH][nM][nS]]` (icalendar's DURATION_REGEX; weeks may come with days).
    private static func duration(_ text: String) throws -> Int {
        let pattern = /([-+]?)P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?/.asciiOnlyDigits()
        guard let m = text.wholeMatch(of: pattern) else { throw ValueError() }
        var seconds = 0
        for (part, unit) in [(m.2, 604_800), (m.3, 86_400), (m.4, 3600), (m.5, 60), (m.6, 1)] {
            guard let part else { continue }
            guard part.count <= 9, let n = Int(part) else { throw ValueError() }  // timedelta's range
            seconds += n * unit
        }
        return m.1 == "-" ? -seconds : seconds
    }

    private static func date(_ s: ArraySlice<Unicode.Scalar>) -> LocalDate? {
        guard s.count == 8, let year = number(s.prefix(4)), let month = number(s.dropFirst(4).prefix(2)),
              let day = number(s.suffix(2)) else { return nil }
        return LocalDate(year: year, month: month, day: day)
    }

    private static func number(_ s: ArraySlice<Unicode.Scalar>) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(String(String.UnicodeScalarView(s)))
    }

    private struct ValueError: Error {}
}

/// A Python `datetime` as icalendar returns it: a wall-clock time in a zone (aware) or without
/// one (floating, Python's naive datetime).
///
/// Python's arithmetic on aware datetimes is wall-clock arithmetic: adding a timedelta moves
/// the wall clock and keeps the zone, and two times in one zone subtract and compare on the
/// wall clock; times in different zones compare as instants. A wall time a DST change skips
/// or repeats is read with fold=0 (`ICalZone.utcOffset(_:)`).
public struct ICalDateTime: Equatable, Sendable, CustomStringConvertible {
    public let wall: LocalDateTime
    /// nil: floating.
    public let zone: ICalZone?

    public init(wall: LocalDateTime, zone: ICalZone?) {
        self.wall = wall
        self.zone = zone
    }

    /// `instant` in `zone` (Python: `aware.astimezone(zone)`).
    public init(_ instant: Date, in zone: ICalZone) {
        self.init(wall: zone.wallClock(at: instant), zone: zone)
    }

    /// `utcoffset()` in seconds; nil when floating.
    public var utcOffset: Int? { zone?.utcOffset(wall) }

    /// nil when floating.
    public var instant: Date? {
        utcOffset.map { LocalDateTime.date(epochMicroseconds: wall.wallMicroseconds - $0 * 1_000_000) }
    }

    /// `self + timedelta(seconds: seconds)`: the wall clock moves, the zone stays.
    public func adding(seconds: Int) -> ICalDateTime {
        ICalDateTime(wall: wall.adding(seconds: seconds), zone: zone)
    }

    /// Python's `self - other` in whole seconds: on the wall clock when both are floating or
    /// share one zone, else between the instants. nil for a floating and an aware time (Python
    /// raises TypeError).
    public func seconds(since other: ICalDateTime) -> Int? {
        switch (zone, other.zone) {
        case (nil, nil):
            return wall.wallSeconds - other.wall.wallSeconds
        case let (a?, b?):
            if a == b { return wall.wallSeconds - other.wall.wallSeconds }
            return (wall.wallSeconds - a.utcOffset(wall)) - (other.wall.wallSeconds - b.utcOffset(other.wall))
        default:
            return nil
        }
    }

    /// Python's `isoformat()`: "2026-10-12T09:00:00+08:00", or without an offset when floating.
    public var description: String {
        utcOffset.map { OffsetDateTime(wall, utcOffset: $0).iso } ?? wall.iso
    }
}
