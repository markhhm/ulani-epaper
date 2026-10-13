import Foundation

/// A wall-clock date and time without a zone, to the microsecond (Python's naive `datetime`,
/// or an aware one seen in its own zone).
///
/// Python compares two aware datetimes that share a tzinfo by their wall-clock fields, and
/// adds a timedelta to the wall clock; this type is that wall clock. The agenda compares
/// events this way (`Event.overlaps`, `AgendaData.eventsOn`), so an event in the hour a DST
/// change repeats sorts by what the clock shows. Converting to an instant needs a zone
/// (`instant(in:)`).
public struct LocalDateTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let date: LocalDate
    /// Seconds since midnight, 0..<86 400.
    public let secondOfDay: Int
    /// 0..<1 000 000 (Python's resolution).
    public let microsecond: Int

    public var hour: Int { secondOfDay / 3600 }
    public var minute: Int { secondOfDay / 60 % 60 }
    public var second: Int { secondOfDay % 60 }

    /// nil unless hour 0...23, minute 0...59, second 0...59 and microsecond 0..<1e6.
    public init?(date: LocalDate, hour: Int, minute: Int, second: Int = 0, microsecond: Int = 0) {
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second),
              (0..<1_000_000).contains(microsecond) else { return nil }
        self.date = date
        self.secondOfDay = hour * 3600 + minute * 60 + second
        self.microsecond = microsecond
    }

    /// 00:00 on `date` (Python: `datetime.combine(date, time())`).
    public init(midnightOf date: LocalDate) {
        self.date = date
        self.secondOfDay = 0
        self.microsecond = 0
    }

    /// The wall-clock time of `instant` in `zone` (Python: `instant.astimezone(zone)`),
    /// rounded to the microsecond.
    public init(_ instant: Date, in zone: TimeZone) {
        let micros = Self.epochMicroseconds(instant)
        let offset = zone.secondsFromGMT(for: instant)
        self.init(wallMicroseconds: micros + offset * 1_000_000)
    }

    /// The instant this wall time names in `zone`, by zoneinfo's fold=0 rules (which
    /// Foundation's `Calendar` follows too): a time skipped by a change (DST gap) takes the
    /// offset from before the change, a repeated time is its first occurrence.
    ///
    /// Python's `agenda.LOCAL` asks the OS (`mktime`), which on macOS takes the offset from
    /// after the change inside a gap (02:30 on a spring-forward day is 01:30 standard time
    /// there, 03:30 daylight time here) and in some zones the second of two repeated times.
    /// Only times that do not exist or exist twice differ.
    public func instant(in zone: TimeZone) -> Date {
        instant(utcOffsetAt: { zone.secondsFromGMT(for: $0) })
    }

    /// `instant(in:)` for any zone given as "UTC offset in seconds at an instant" (for example
    /// a calendar's own VTIMEZONE). Assumes at most one offset change within a day of the time.
    public func instant(utcOffsetAt offsetAt: (Date) throws -> Int) rethrows -> Date {
        let w = wallSeconds
        func offset(at seconds: Int) throws -> Int { try offsetAt(Date(timeIntervalSince1970: TimeInterval(seconds))) }
        let before = try offset(at: w - 86_400)
        let after = try offset(at: w + 86_400)
        var chosen = before
        if before != after, try offset(at: w - before) != before, try offset(at: w - after) == after {
            chosen = after  // only the later offset names this time
        }
        return Self.date(epochMicroseconds: (w - chosen) * 1_000_000 + microsecond)
    }

    /// Wall-clock arithmetic (Python: `aware + timedelta(seconds=...)` moves the wall time by
    /// exactly that much, whatever the zone does).
    public func adding(seconds: Int) -> LocalDateTime {
        LocalDateTime(wallMicroseconds: wallMicroseconds + seconds * 1_000_000)
    }

    /// Python: `dt + timedelta(microseconds=n)` (`layouts._span_note` steps back by one).
    public func adding(microseconds: Int) -> LocalDateTime {
        LocalDateTime(wallMicroseconds: wallMicroseconds + microseconds)
    }

    /// "YYYY-MM-DDTHH:MM:SS", plus ".ffffff" when there is a fraction (Python's `isoformat()`).
    public var iso: String {
        let p = LocalDate.pad
        let text = "\(date.iso)T\(p(hour, 2)):\(p(minute, 2)):\(p(second, 2))"
        return microsecond == 0 ? text : text + "." + p(microsecond, 6)
    }

    public var description: String { iso }

    public static func < (a: LocalDateTime, b: LocalDateTime) -> Bool {
        (a.date, a.secondOfDay, a.microsecond) < (b.date, b.secondOfDay, b.microsecond)
    }

    // MARK: Counting on the wall clock since 1970-01-01T00:00

    /// Whole seconds (the fraction dropped).
    var wallSeconds: Int { date.daysSince1970 * 86_400 + secondOfDay }

    var wallMicroseconds: Int { wallSeconds * 1_000_000 + microsecond }

    init(wallMicroseconds: Int) {
        let (days, rest) = Self.floorDivide(wallMicroseconds, 86_400 * 1_000_000)
        self.date = LocalDate(daysSince1970: days)
        self.secondOfDay = rest / 1_000_000
        self.microsecond = rest % 1_000_000
    }

    /// (quotient, remainder) with the remainder in 0..<divisor.
    static func floorDivide(_ value: Int, _ divisor: Int) -> (Int, Int) {
        let q = value / divisor, r = value % divisor
        return r < 0 ? (q - 1, r + divisor) : (q, r)
    }

    /// `instant` as whole microseconds since 1970 (Python's resolution; rounded to the nearest).
    static func epochMicroseconds(_ instant: Date) -> Int {
        Int((instant.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// The instant `micros` microseconds after 1970. Every instant this module makes goes
    /// through here, so equal microsecond counts give equal `Date`s.
    static func date(epochMicroseconds micros: Int) -> Date {
        let (seconds, fraction) = floorDivide(micros, 1_000_000)
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(fraction) / 1_000_000)
    }
}
