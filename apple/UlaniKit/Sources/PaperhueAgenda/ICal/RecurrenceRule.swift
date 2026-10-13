import Foundation

/// An event's RRULE as the Python reference expands it: read by icalendar (`vRecur`), written
/// again and read by dateutil (`rrulestr`), expanded by dateutil's `rrule` on DTSTART's wall
/// clock (so a series keeps its local time across DST changes).
///
/// FREQ=YEARLY, MONTHLY, WEEKLY or DAILY with INTERVAL, COUNT, UNTIL, BYMONTH, BYMONTHDAY (±),
/// BYDAY (with ordinals; BYWEEKDAY is the same), BYSETPOS (±) and WKST, with dateutil's
/// quirks: without BYDAY or BYMONTHDAY the rule takes DTSTART's day (and month, yearly);
/// ordinals count only in yearly and monthly rules; plain and numbered weekdays must both
/// match; BYMONTHDAY=0 matches every day; a weekly rule's first week starts at DTSTART; the
/// series ends in the year 9999.
///
/// Any other rule cannot be read (the event is then skipped and counted): SECONDLY, MINUTELY,
/// HOURLY, BYWEEKNO, BYYEARDAY, BYHOUR, BYMINUTE, BYSECOND and other parts, a zero or negative
/// INTERVAL (which dateutil may never finish), and anything icalendar or dateutil refuses.
struct RecurrenceRule: Sendable {
    /// dateutil's order: YEARLY < MONTHLY < WEEKLY < DAILY.
    enum Frequency: Int, Sendable {
        case yearly, monthly, weekly, daily
    }

    private struct Unreadable: Error {}

    let frequency: Frequency
    private(set) var interval = 1
    private(set) var count: Int?
    /// UNTIL as written (ical.py turns it into a bound for the event's DTSTART).
    private(set) var until: ICalValue?
    private var months: [Int]?
    private var monthDays: [Int]?
    /// Weekday (Monday 0) and ordinal (0: every one).
    private var weekdays: [(weekday: Int, ordinal: Int)]?
    private var setPositions: [Int] = []
    /// Monday 0.
    private var weekStart = 0

    private static let frequencies = ["YEARLY", "MONTHLY", "WEEKLY", "DAILY"]
    private static let dayNames = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

    /// Throws `Unreadable`.
    init(_ text: String) throws {
        // icalendar: NAME=v1,v2 parts, names in any case, a part without exactly one "=" ignored
        var parts: [String: [String]] = [:]
        for part in text.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = part.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let values = pair[1].split(separator: ",", omittingEmptySubsequences: false)
            parts[pair[0].uppercased()] = values.map(String.init)
        }
        guard let freq = parts.removeValue(forKey: "FREQ"), freq.count == 1,
              let f = Self.frequencies.firstIndex(of: freq[0].uppercased()) else { throw Unreadable() }
        frequency = Frequency(rawValue: f)!
        for (name, values) in parts {
            switch name {
            case "INTERVAL":
                interval = try Self.single(values, Self.int)
                guard interval >= 1 else { throw Unreadable() }
            case "COUNT":
                count = try Self.single(values, Self.int)
            case "UNTIL":
                let all = try values.map { try ICalValue.parse($0, zone: nil) }
                until = all[0]
            case "BYMONTH":
                months = try values.map { text in  // vMonth: digits only
                    guard !text.isEmpty, text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                          let n = Int(text) else { throw Unreadable() }
                    return n
                }
            case "BYMONTHDAY":
                monthDays = try values.map(Self.int)
            case "BYSETPOS":
                setPositions = try values.map(Self.int)
                guard setPositions.allSatisfy({ $0 != 0 && (-366...366).contains($0) }) else { throw Unreadable() }
            case "BYDAY", "BYWEEKDAY":
                let days = try values.map(Self.weekday)
                if name == "BYWEEKDAY" || parts["BYWEEKDAY"] == nil { weekdays = days }  // BYWEEKDAY is written last
            case "WKST":
                weekStart = try Self.single(values) { text in
                    guard let day = Self.dayNames.firstIndex(of: text.uppercased()) else { throw Unreadable() }
                    return day
                }
            default:
                throw Unreadable()
            }
        }
        if frequency == .yearly, weekdays?.contains(where: { $0.ordinal != 0 }) == true,
           months?.contains(where: { !(1...12).contains($0) }) == true {
            throw Unreadable()  // dateutil fails on the month's range
        }
    }

    /// The rule's occurrences from `start` on (wall-clock times at `start`'s time of day), in
    /// order, as dateutil's rrule yields them, until `isPastUntil` holds for one or `body`
    /// returns false.
    func forEach(from start: LocalDateTime, isPastUntil: (LocalDateTime) -> Bool,
                 _ body: (LocalDateTime) throws -> Bool) rethrows {
        var months = months, monthDays = monthDays, weekdays = weekdays
        if monthDays == nil && weekdays == nil {  // dateutil's defaults from DTSTART
            switch frequency {
            case .yearly:
                months = months ?? [start.date.month]
                monthDays = [start.date.day]
            case .monthly:
                monthDays = [start.date.day]
            case .weekly:
                weekdays = [(start.date.weekday, 0)]
            case .daily:
                break
            }
        }
        let monthSet = months.map(Set.init)
        let positiveDays = Set((monthDays ?? []).filter { $0 > 0 })
        let negativeDays = Set((monthDays ?? []).filter { $0 < 0 })
        var plain = Set<Int>()
        var numbered: [(weekday: Int, ordinal: Int)] = []
        for day in weekdays ?? [] {
            if day.ordinal == 0 || frequency.rawValue > Frequency.monthly.rawValue {
                plain.insert(day.weekday)
            } else {
                numbered.append(day)
            }
        }

        var current = start.date  // the period's first day
        var remaining = count
        while true {
            let days = period(from: current)
            let nth = numbered.isEmpty ? [] : Self.nthDays(numbered, in: ranges(of: current, months: monthSet))
            var matched = days.filter { date in
                if let monthSet, !monthSet.contains(date.month) { return false }
                if !plain.isEmpty && !plain.contains(date.weekday) { return false }
                if !numbered.isEmpty && !nth.contains(date) { return false }
                if !positiveDays.isEmpty || !negativeDays.isEmpty {
                    let length = LocalDate.daysInMonth(year: date.year, month: date.month)
                    return positiveDays.contains(date.day) || negativeDays.contains(date.day - length - 1)
                }
                return true
            }
            if !setPositions.isEmpty {
                var picked: [LocalDate] = []
                for position in setPositions {
                    let i = position < 0 ? matched.count + position : position - 1
                    if matched.indices.contains(i) && !picked.contains(matched[i]) { picked.append(matched[i]) }
                }
                matched = picked.sorted()
            }
            for date in matched {
                let occurrence = LocalDateTime(midnightOf: date).adding(seconds: start.secondOfDay)
                if isPastUntil(occurrence) { return }
                guard occurrence >= start else { continue }
                if let n = remaining {
                    if n <= 0 { return }
                    remaining = n - 1
                }
                guard try body(occurrence) else { return }
            }
            switch frequency {
            case .yearly:
                current = LocalDate(year: current.year + interval, month: 1, day: 1)!
            case .monthly:
                let month = current.month - 1 + interval
                current = LocalDate(year: current.year + month / 12, month: month % 12 + 1, day: 1)!
            case .weekly:  // the next period starts on WKST
                current = current.adding(days: 7 * interval - (current.weekday - weekStart + 7) % 7)
            case .daily:
                current = current.adding(days: interval)
            }
            if current.year > LocalDate.max.year { return }
        }
    }

    /// The days of the period that starts at `first` (a year or a month from its 1st, or the
    /// days of a week up to the next WKST, or one day).
    private func period(from first: LocalDate) -> [LocalDate] {
        let start: LocalDate, end: LocalDate  // end exclusive
        switch frequency {
        case .yearly:
            start = LocalDate(year: first.year, month: 1, day: 1)!
            end = LocalDate(year: first.year + 1, month: 1, day: 1)!
        case .monthly:
            start = first.firstOfMonth
            end = first.firstOfNextMonth
        case .weekly:
            start = first
            end = first.adding(days: 7 - (first.weekday - weekStart + 7) % 7)
        case .daily:
            start = first
            end = first.adding(days: 1)
        }
        return Array(start..<end)
    }

    /// Where numbered weekdays count: the year or its BYMONTH months (yearly), the month (monthly).
    private func ranges(of first: LocalDate, months: Set<Int>?) -> [ClosedRange<LocalDate>] {
        if frequency == .monthly {
            return [first.firstOfMonth...first.firstOfNextMonth.adding(days: -1)]
        }
        guard let months else {
            return [LocalDate(year: first.year, month: 1, day: 1)!...LocalDate(year: first.year, month: 12, day: 31)!]
        }
        return months.sorted().map { month in
            let start = LocalDate(year: first.year, month: month, day: 1)!
            return start...start.firstOfNextMonth.adding(days: -1)
        }
    }

    /// The n-th (from the end when negative) of a weekday in each range.
    private static func nthDays(_ numbered: [(weekday: Int, ordinal: Int)], in ranges: [ClosedRange<LocalDate>])
        -> Set<LocalDate> {
        var days = Set<LocalDate>()
        for range in ranges {
            for (weekday, n) in numbered {
                let day = n > 0
                    ? range.lowerBound.adding(days: (n - 1) * 7 + (weekday - range.lowerBound.weekday + 7) % 7)
                    : range.upperBound.adding(days: (n + 1) * 7 - (range.upperBound.weekday - weekday + 7) % 7)
                if range.contains(day) { days.insert(day) }
            }
        }
        return days
    }

    private static func single<T>(_ values: [String], _ read: (String) throws -> T) throws -> T {
        guard values.count == 1 else { throw Unreadable() }
        return try read(values[0])
    }

    /// Python's `int()` (surrounding whitespace, a sign) within icalendar's INTEGER range.
    private static func int(_ text: String) throws -> Int {
        guard let n = Int(Note.strip(text.unicodeScalars)), (-2_147_483_648...2_147_483_647).contains(n) else {
            throw Unreadable()
        }
        return n
    }

    /// `MO`, `1MO`, `+2TU`, `-1SU` (icalendar's pattern; dateutil refuses a sign without a
    /// number and the ordinal 0).
    private static func weekday(_ text: String) throws -> (weekday: Int, ordinal: Int) {
        let s = Array(text.uppercased().unicodeScalars)
        guard s.count >= 2, let day = dayNames.firstIndex(of: String(String.UnicodeScalarView(s.suffix(2)))) else {
            throw Unreadable()
        }
        let prefix = s.dropLast(2)
        let sign = prefix.first == "+" || prefix.first == "-" ? prefix.first : nil
        let digits = prefix.dropFirst(sign == nil ? 0 : 1)
        guard digits.count <= 2, digits.allSatisfy({ ("0"..."9").contains($0) }) else { throw Unreadable() }
        if digits.isEmpty {
            guard sign == nil else { throw Unreadable() }
            return (day, 0)
        }
        let n = Int(String(String.UnicodeScalarView(digits)))!
        guard n != 0 else { throw Unreadable() }
        return (day, sign == "-" ? -n : n)
    }
}
