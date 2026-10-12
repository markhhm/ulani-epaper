import Foundation

/// A feed's own VTIMEZONE, for a TZID that is not an IANA name (Outlook's Windows names,
/// "Customized Time Zone", ...), read as the Python reference reads it (icalendar hands it to
/// dateutil's `tzical`).
///
/// Each STANDARD / DAYLIGHT observance applies from its onsets on: DTSTART, the RRULE's
/// occurrences and RDATE, less EXDATE, all wall-clock times as written. A wall time takes the
/// observance with the latest onset at or before it (the first one listed on a tie), so a time
/// a change skips already counts as after the change, and a repeated time is its first
/// occurrence. Before every onset the first STANDARD observance applies.
///
/// RRULE: the yearly rules zone definitions use (BYMONTH with BYDAY, with or without an
/// ordinal, BYMONTHDAY, INTERVAL, UNTIL, COUNT). Any other rule makes the definition unreadable.
public final class VTimezone: Hashable, Sendable {
    public let tzid: String
    private let observances: [Observance]

    /// Throws `ICalError` when the definition cannot be read.
    init(_ component: ICalComponent) throws {
        tzid = component.first("TZID")?.text ?? ""
        do {
            observances = try component.components.map(Observance.init)
        } catch {
            throw ICalError(reason: "an unreadable VTIMEZONE")
        }
        guard !observances.isEmpty else { throw ICalError(reason: "an unreadable VTIMEZONE") }
    }

    /// The UTC offset of `wall` in seconds. `fold`: the second of two repeated times (dateutil
    /// judges a time in an observance that turns the clock back as that much later).
    func utcOffset(_ wall: LocalDateTime, fold: Bool = false) -> Int {
        if observances.count == 1 { return observances[0].offsetTo }
        var latest: (onset: LocalDateTime, observance: Observance)?
        for o in observances {
            let t = fold && o.offsetTo < o.offsetFrom ? wall.adding(seconds: o.offsetFrom - o.offsetTo) : wall
            if let onset = o.lastOnset(atOrBefore: t), latest == nil || latest!.onset < onset {
                latest = (onset, o)
            }
        }
        return (latest?.observance ?? observances.first { !$0.isDaylight } ?? observances[0]).offsetTo
    }

    /// The wall clock at `instant`: the wall time whose offset gives it back, the first of two
    /// repeated times first.
    func wallClock(at instant: Date) -> LocalDateTime {
        let utc = LocalDateTime(wallMicroseconds: LocalDateTime.epochMicroseconds(instant))
        for fold in [false, true] {
            for o in observances where utcOffset(utc.adding(seconds: o.offsetTo), fold: fold) == o.offsetTo {
                return utc.adding(seconds: o.offsetTo)
            }
        }
        return utc.adding(seconds: utcOffset(utc))
    }

    public static func == (a: VTimezone, b: VTimezone) -> Bool { a === b }

    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    private struct Observance: Sendable {
        let offsetFrom: Int
        let offsetTo: Int
        let isDaylight: Bool
        let start: LocalDateTime
        let rule: YearlyRule?
        let dates: [LocalDateTime]
        let excluded: Set<LocalDateTime>

        init(_ c: ICalComponent) throws {
            guard c.name == "STANDARD" || c.name == "DAYLIGHT", let start = c.first("DTSTART")?.value,
                  let from = c.first("TZOFFSETFROM"), let to = c.first("TZOFFSETTO") else { throw Unreadable() }
            isDaylight = c.name == "DAYLIGHT"
            offsetFrom = try Self.offset(from.raw)
            offsetTo = try Self.offset(to.raw)
            self.start = try VTimezone.wall(start)
            rule = try c.first("RRULE").map { try YearlyRule($0.raw) }
            dates = try c.all("RDATE").flatMap(\.values).map(VTimezone.wall)
            excluded = Set(try c.all("EXDATE").flatMap(\.values).map(VTimezone.wall))
        }

        func lastOnset(atOrBefore t: LocalDateTime) -> LocalDateTime? {
            let listed = ([start] + dates).filter { $0 <= t && !excluded.contains($0) }.max()
            guard let ruled = rule?.lastOnset(from: start, atOrBefore: t, skipping: excluded) else { return listed }
            return max(listed ?? ruled, ruled)
        }

        /// `+0800`, `-0430`, `+053000`.
        private static func offset(_ text: String) throws -> Int {
            let s = Array(text.trimmingCharacters(in: .whitespaces).unicodeScalars)
            let sign = s.first == "-" ? -1 : 1
            let digits = s.first == "+" || s.first == "-" ? Array(s.dropFirst()) : s
            guard digits.count == 4 || digits.count == 6, digits.allSatisfy({ ("0"..."9").contains($0) }) else {
                throw Unreadable()
            }
            let n = digits.map { Int($0.value) - 48 }
            let seconds = (n[0] * 10 + n[1]) * 3600 + (n[2] * 10 + n[3]) * 60 + (n.count == 6 ? n[4] * 10 + n[5] : 0)
            guard seconds < 86_400 else { throw Unreadable() }
            return sign * seconds
        }
    }

    /// `FREQ=YEARLY` as dateutil's rrule expands it for one observance.
    private struct YearlyRule: Sendable {
        var interval = 1
        var count: Int?
        var until: LocalDateTime?
        var months: [Int] = []
        /// (ordinal within the month, 0 for every; weekday, Monday 0).
        var weekdays: [(ordinal: Int, weekday: Int)] = []
        var monthDays: [Int] = []

        init(_ text: String) throws {
            var yearly = false
            for part in text.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { String($0).uppercased() }
                guard kv.count == 2 else { throw Unreadable() }
                let list = kv[1].split(separator: ",").map(String.init)
                switch kv[0] {
                case "FREQ": yearly = kv[1] == "YEARLY"
                case "INTERVAL": interval = try Self.int(kv[1], 1...)
                case "COUNT": count = try Self.int(kv[1], 0...)
                case "UNTIL": until = try VTimezone.wall(try ICalValue.parse(kv[1], zone: nil))
                case "BYMONTH": months = try list.map { try Self.int($0, 1...12) }.sorted()
                case "BYMONTHDAY": monthDays = try list.map { try Self.int($0, -31...31) }
                case "BYDAY": weekdays = try list.map(Self.weekday)
                case "WKST": break  // no effect on these rules
                default: throw Unreadable()
                }
            }
            if months.isEmpty && (weekdays.contains { $0.ordinal != 0 }) { throw Unreadable() }  // nth of the year
            guard yearly else { throw Unreadable() }
        }

        /// The latest occurrence at or before `t` that `excluded` does not remove.
        func lastOnset(from start: LocalDateTime, atOrBefore t: LocalDateTime, skipping excluded: Set<LocalDateTime>)
            -> LocalDateTime? {
            if let count {  // the first `count` occurrences
                var last: LocalDateTime?
                var n = 0
                for year in stride(from: start.date.year, through: min(t.date.year, 9999), by: interval) {
                    for onset in onsets(in: year, from: start) {
                        guard n < count, onset <= t else { return last }
                        n += 1
                        if !excluded.contains(onset) { last = onset }
                    }
                }
                return last
            }
            var year = min(t.date.year, until?.date.year ?? t.date.year)
            guard year >= start.date.year else { return nil }
            year -= (year - start.date.year) % interval
            for y in stride(from: year, through: start.date.year, by: -interval) {
                if let onset = onsets(in: y, from: start).last(where: { $0 <= t && !excluded.contains($0) }) {
                    return onset
                }
            }
            return nil
        }

        /// The year's occurrences in order, from `start` on and up to UNTIL, at `start`'s time.
        private func onsets(in year: Int, from start: LocalDateTime) -> [LocalDateTime] {
            var found: [LocalDateTime] = []
            let everyMonth = weekdays.isEmpty && monthDays.isEmpty ? [start.date.month] : Array(1...12)
            for month in months.isEmpty ? everyMonth : months {
                let length = LocalDate.daysInMonth(year: year, month: month)
                for day in 1...length {
                    guard let date = LocalDate(year: year, month: month, day: day), matches(date, length, start) else {
                        continue
                    }
                    let onset = LocalDateTime(midnightOf: date).adding(seconds: start.secondOfDay)
                    if onset >= start && (until == nil || onset <= until!) { found.append(onset) }
                }
            }
            return found
        }

        /// Without BYDAY and BYMONTHDAY, the day of DTSTART.
        private func matches(_ date: LocalDate, _ length: Int, _ start: LocalDateTime) -> Bool {
            if weekdays.isEmpty && monthDays.isEmpty { return date.day == start.date.day }
            if !monthDays.isEmpty && !monthDays.contains(where: { ($0 > 0 ? $0 : length + 1 + $0) == date.day }) {
                return false
            }
            return weekdays.isEmpty || weekdays.contains {
                $0.weekday == date.weekday && ($0.ordinal == 0
                    || ($0.ordinal > 0 ? (date.day - 1) / 7 + 1 : -((length - date.day) / 7 + 1)) == $0.ordinal)
            }
        }

        private static func int(_ text: String, _ range: some RangeExpression<Int>) throws -> Int {
            guard let n = Int(text), range.contains(n) else { throw Unreadable() }
            return n
        }

        /// `SU`, `1SU`, `-1SU`.
        private static func weekday(_ text: String) throws -> (ordinal: Int, weekday: Int) {
            let names = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
            guard let day = names.firstIndex(of: String(text.suffix(2))) else { throw Unreadable() }
            let ordinal = text.dropLast(2)
            return (ordinal.isEmpty ? 0 : try int(String(ordinal), -5...5), day)
        }
    }

    /// dateutil reads onsets without their zone: a `Z` is ignored, a date is midnight.
    private static func wall(_ value: ICalValue) throws -> LocalDateTime {
        switch value {
        case .date(let d): return LocalDateTime(midnightOf: d)
        case .dateTime(let t): return t.wall
        case .duration, .period: throw Unreadable()
        }
    }

    private struct Unreadable: Error {}
}
