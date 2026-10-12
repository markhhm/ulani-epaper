import Foundation

/// A calendar date without a time zone, in the proleptic Gregorian calendar (Python's `date`).
///
/// Arithmetic is plain integer day counting: no Julian switch in 1582 and no Foundation
/// `Calendar`. Python's `date` covers years 1...9999 (`LocalDate.min`...`LocalDate.max`);
/// here any year is allowed, so code that mirrors Python's limits checks `year` itself.
public struct LocalDate: Hashable, Comparable, Strideable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Python's `date.min` and `date.max`.
    public static let min = LocalDate(unchecked: 1, 1, 1)
    public static let max = LocalDate(unchecked: 9999, 12, 31)

    /// nil unless `month` is 1...12 and `day` exists in that month.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= Self.daysInMonth(year: year, month: month) else {
            return nil
        }
        self.init(unchecked: year, month, day)
    }

    private init(unchecked year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Python's `date.fromordinal`: day 1 is 0001-01-01.
    public init(ordinal: Int) {
        self.init(daysSince1970: ordinal - Self.ordinalOf1970)
    }

    /// The local date of `instant` in `zone` (Python: `instant.astimezone(zone).date()`).
    public init(_ instant: Date, in zone: TimeZone) {
        self = LocalDateTime(instant, in: zone).date
    }

    /// Today in `zone` (Python: `datetime.now(zone).date()`); `now` is injectable for tests.
    public static func today(in zone: TimeZone, now: Date = Date()) -> LocalDate {
        LocalDate(now, in: zone)
    }

    /// Strict ISO 8601 extended date "YYYY-MM-DD" with a year 0001...9999 (what Python's
    /// `date.isoformat()` writes); nil for anything else. Python's `date.fromisoformat` also
    /// takes the basic ("20261012") and week ("2026-W41-1") forms; nothing Paperhue reads uses them.
    public init?(iso text: String) {
        let b = Array(text.utf8)
        guard b.count == 10, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              let y = Self.digits(b[0..<4]), let m = Self.digits(b[5..<7]), let d = Self.digits(b[8..<10]),
              y >= 1 else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Python's `date.toordinal()`: 0001-01-01 is 1.
    public var ordinal: Int { daysSince1970 + Self.ordinalOf1970 }

    /// Monday 0 ... Sunday 6 (Python's `date.weekday()`).
    public var weekday: Int { ((ordinal + 6) % 7 + 7) % 7 }

    /// Python: `date + timedelta(days=n)`.
    public func adding(days: Int) -> LocalDate { LocalDate(daysSince1970: daysSince1970 + days) }

    /// Days from `self` to `other` (Python: `(other - self).days`).
    public func distance(to other: LocalDate) -> Int { other.daysSince1970 - daysSince1970 }

    public func advanced(by n: Int) -> LocalDate { adding(days: n) }

    /// The 1st of this date's month (Python: `date.replace(day=1)`).
    public var firstOfMonth: LocalDate { LocalDate(unchecked: year, month, 1) }

    /// The 1st of the following month (feeds.window: `(first + timedelta(days=32)).replace(day=1)`).
    public var firstOfNextMonth: LocalDate {
        month == 12 ? LocalDate(unchecked: year + 1, 1, 1) : LocalDate(unchecked: year, month + 1, 1)
    }

    /// The instant this date starts in `zone`: 00:00 by zoneinfo's fold=0 rules (see
    /// `LocalDateTime.instant(in:)`).
    public func midnight(in zone: TimeZone) -> Date {
        LocalDateTime(midnightOf: self).instant(in: zone)
    }

    /// "YYYY-MM-DD" (at least four year digits).
    public var iso: String {
        let y = year < 0 ? "-" + Self.pad(-year, 4) : Self.pad(year, 4)
        return "\(y)-\(Self.pad(month, 2))-\(Self.pad(day, 2))"
    }

    public var description: String { iso }

    public static func < (a: LocalDate, b: LocalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    /// Days in `month` (1...12) of `year`; 0 for an invalid month.
    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: isLeapYear(year) ? 29 : 28
        default: 0
        }
    }

    /// The weeks a month page shows: whole weeks starting on `firstWeekday` (Monday 0 ...
    /// Sunday 6), from the week of the 1st to the week of the last day (Python:
    /// `calendar.Calendar(firstweekday).monthdatescalendar(year, month)`). 4 to 6 weeks of 7 dates.
    public static func monthWeeks(year: Int, month: Int, firstWeekday: Int) -> [[LocalDate]] {
        guard let first = LocalDate(year: year, month: month, day: 1) else { return [] }
        let last = first.adding(days: daysInMonth(year: year, month: month) - 1)
        var start = first.adding(days: -(((first.weekday - firstWeekday) % 7 + 7) % 7))
        var weeks: [[LocalDate]] = []
        while start <= last {
            weeks.append((0..<7).map { start.adding(days: $0) })
            start = start.adding(days: 7)
        }
        return weeks
    }

    // MARK: Day counting (Howard Hinnant's days_from_civil / civil_from_days)

    static let ordinalOf1970 = 719_163

    /// Days since 1970-01-01 (negative before).
    var daysSince1970: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1  // from March 1st
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    init(daysSince1970 days: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let d = dayOfYear - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(unchecked: yearOfEra + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    // MARK: Text helpers

    /// ASCII digits only -> value; nil for anything else (signs, spaces, other scripts).
    static func digits(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty else { return nil }
        var value = 0
        for b in bytes {
            guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(b - UInt8(ascii: "0"))
        }
        return value
    }

    /// Non-negative `value` zero-padded to `width` digits.
    static func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}
