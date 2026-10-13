import Foundation

/// One calendar's events and open to-dos (Python: `ical.ParsedFeed`).
public struct ParsedFeed: FeedContents, Hashable, Sendable {
    /// The name given, else the calendar's X-WR-CALNAME.
    public var name: String
    public var events: [Event]
    public var tasks: [AgendaTask]
    /// Events and to-dos that could not be read (a broken or unsupported rule, no start, ...).
    public var skipped: Int

    public init(name: String, events: [Event] = [], tasks: [AgendaTask] = [], skipped: Int = 0) {
        self.name = name
        self.events = events
        self.tasks = tasks
        self.skipped = skipped
    }
}

/// Events and to-dos from iCalendar data, as python/src/ulani_epaper/ical.py `parse` reads them.
/// Nothing is kept: the bytes come in, events and to-dos go out.
public enum ICal {
    /// At most this many occurrences of one recurring event inside the window.
    public static let maxOccurrences = 500
    /// Occurrences walked from DTSTART before a series is given up as runaway (skipped).
    public static let maxSteps = 200_000

    /// The events overlapping [start, end) and all open to-dos of one .ics file (Python:
    /// `ical.parse`).
    ///
    /// Recurring events are expanded in the window (RRULE as `RecurrenceRule` reads it, RDATE,
    /// EXDATE); a VEVENT with RECURRENCE-ID replaces the occurrence it names, a cancelled one
    /// removes it, and STATUS:CANCELLED on a series removes the series. Events whose ATTENDEE
    /// line for `owner` (an e-mail address) says DECLINED are left out. All-day dates and due
    /// dates are read in `zone`; floating times in the calendar's X-WR-TIMEZONE, else `zone`.
    /// `name` and `color` ("#rrggbb") go onto every event and to-do. An event or to-do that
    /// cannot be read is skipped and counted. Throws `ICalError` for data that is not iCalendar.
    public static func parse(_ data: Data, start: Date, end: Date, zone: TimeZone, name: String = "",
                             color: String = "", owner: String = "") throws -> ParsedFeed {
        let calendar = try ICalendar.read(data)
        let zoneNames = calendar.all("X-WR-TIMEZONE")  // a repeated one is a list to Python: no zone
        let floating = (zoneNames.count == 1 ? ICalZone.zoneinfo(text(zoneNames[0])) : nil) ?? .system(zone)
        let reader = Reader(start: start, end: end, zone: zone, floating: floating)
        var feed = ParsedFeed(name: name.isEmpty ? text(calendar, "X-WR-CALNAME") : name)

        var masters: [ICalComponent] = []
        var overrides: [[ICalComponent]] = []
        var groupOfUID: [[Unicode.Scalar]: Int] = [:]  // by code points, as Python's dict
        for component in calendar.walk("VEVENT") {
            guard component.contains("RECURRENCE-ID") else {
                masters.append(component)
                continue
            }
            let uid = Array(text(component, "UID").unicodeScalars)
            if let i = groupOfUID[uid] {
                overrides[i].append(component)
            } else {
                groupOfUID[uid] = overrides.count
                overrides.append([component])
            }
        }

        for component in masters where !isCancelled(component) && !declined(component, owner) {
            do {
                let (base, length, allDay) = try reader.startAndLength(component)
                let replaced = groupOfUID[Array(text(component, "UID").unicodeScalars)].map { overrides[$0] } ?? []
                let moved = Set(try replaced.compactMap { try reader.key(of: $0, allDay) })
                for begin in try reader.occurrences(component, base, length)
                where !moved.contains(reader.key(begin, allDay)) {
                    feed.events.append(reader.event(component, begin, length, allDay, feed.name, color))
                }
            } catch {
                feed.skipped += 1
            }
        }

        for component in overrides.joined() where !isCancelled(component) && !declined(component, owner) {
            do {
                let (base, length, allDay) = try reader.startAndLength(component)
                let (lo, hi) = reader.window(base)
                if Reader.overlaps(base, length, lo, hi) {
                    feed.events.append(reader.event(component, base, length, allDay, feed.name, color))
                }
            } catch {
                feed.skipped += 1
            }
        }

        for component in calendar.walk("VTODO") {
            do {
                if let task = try reader.task(component, feed.name) { feed.tasks.append(task) }
            } catch {
                feed.skipped += 1
            }
        }
        return feed
    }

    /// `parse` with a calendar source's window, zone, name, colour and owner: the parse step of
    /// `Feeds.fetch` and `Feeds.probe`.
    public static func parse(_ data: Data, _ context: FeedContext) throws -> ParsedFeed {
        try parse(data, start: context.start, end: context.end, zone: context.zone, name: context.name,
                  color: context.color, owner: context.owner)
    }

    // MARK: Properties

    /// An event or to-do that cannot be read: skipped and counted.
    private struct Unreadable: Error {}

    /// Python's `_text`: the first such property as text, without outer whitespace.
    private static func text(_ component: ICalComponent, _ name: String) -> String {
        component.first(name).map(text) ?? ""
    }

    private static func text(_ property: ICalProperty) -> String { Note.strip(property.text.unicodeScalars) }

    /// A date/time property's one value (Python's `decoded`): missing, repeated, broken or a
    /// list cannot be read.
    private static func single(_ component: ICalComponent, _ name: String) throws -> ICalValue {
        let found = component.all(name)
        guard found.count == 1, !found[0].isBroken, found[0].values.count == 1 else { throw Unreadable() }
        return found[0].values[0]
    }

    private static func isCancelled(_ component: ICalComponent) -> Bool {
        text(component, "STATUS").uppercased() == "CANCELLED"
    }

    /// The owner's own ATTENDEE line says PARTSTAT=DECLINED (Google keeps declined invitations in
    /// the feed; this is the only sign of the decline). The first line for the owner decides.
    private static func declined(_ component: ICalComponent, _ owner: String) -> Bool {
        guard !owner.isEmpty else { return false }
        let me = Array(PythonURL.pythonLower(owner).unicodeScalars)
        for attendee in component.all("ATTENDEE") {
            var address = Array(PythonURL.pythonLower(attendee.text).unicodeScalars)
            if address.starts(with: "mailto:".unicodeScalars) { address.removeFirst(7) }
            if address == me { return (attendee.parameter("PARTSTAT") ?? "").uppercased() == "DECLINED" }
        }
        return false
    }

    /// Python's `str.splitlines()` line boundaries.
    private static func isLineBreak(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x0A...0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    // MARK: Times

    /// Python's `_Reader`. Times are `ICalDateTime`s: aware, or floating (Python's naive
    /// datetimes) for all-day events and floating times, compared as Python compares them.
    private struct Reader {
        let start: Date
        let end: Date
        /// The page's zone.
        let zone: TimeZone
        /// Floating times are in this zone.
        let floating: ICalZone

        /// The window in the kind of `sample`: instants, or wall times in the floating zone.
        func window(_ sample: ICalDateTime) -> (ICalDateTime, ICalDateTime) {
            if sample.zone != nil {
                return (ICalDateTime(start, in: .fixed(seconds: 0)), ICalDateTime(end, in: .fixed(seconds: 0)))
            }
            return (ICalDateTime(wall: floating.wallClock(at: start), zone: nil),
                    ICalDateTime(wall: floating.wallClock(at: end), zone: nil))
        }

        /// `value` as the same kind as `base`: a date at `base`'s time (midnight when floating),
        /// a floating time in `base`'s zone, an aware time as it is (seen in the floating zone
        /// when `base` is floating).
        func like(_ value: ICalValue, _ base: ICalDateTime) throws -> ICalDateTime {
            switch value {
            case .date(let d):
                let midnight = LocalDateTime(midnightOf: d)
                return base.zone == nil ? ICalDateTime(wall: midnight, zone: nil)
                    : ICalDateTime(wall: midnight.adding(seconds: base.wall.secondOfDay), zone: base.zone)
            case .dateTime(let t):
                if base.zone != nil { return t.zone == nil ? ICalDateTime(wall: t.wall, zone: base.zone) : t }
                guard let instant = t.instant else { return t }
                return ICalDateTime(wall: floating.wallClock(at: instant), zone: nil)
            case .duration, .period:
                throw Unreadable()
            }
        }

        /// RRULE UNTIL as dateutil gets it for this DTSTART: a date means through that day; for
        /// an aware DTSTART, a UTC instant (a floating UNTIL in DTSTART's zone).
        func until(_ value: ICalValue, _ base: ICalDateTime) throws -> ICalDateTime {
            var value = value
            if case .date(let d) = value {
                value = .dateTime(ICalDateTime(wall: LocalDateTime(midnightOf: d).adding(seconds: 86_399), zone: nil))
            }
            guard base.zone != nil else { return try like(value, base) }
            guard case .dateTime(let t) = value,
                  let instant = ICalDateTime(wall: t.wall, zone: t.zone ?? base.zone).instant else {
                throw Unreadable()
            }
            return ICalDateTime(instant, in: .utc)
        }

        /// Python's `start_and_duration`: DTSTART (a date: all day, from its midnight), and the
        /// length in seconds from DTEND, else DURATION, else a day (all day) or none; all-day
        /// events last at least a day.
        func startAndLength(_ component: ICalComponent) throws -> (ICalDateTime, Int, Bool) {
            let base: ICalDateTime, allDay: Bool
            switch try single(component, "DTSTART") {
            case .date(let d): (base, allDay) = (ICalDateTime(wall: LocalDateTime(midnightOf: d), zone: nil), true)
            case .dateTime(let t): (base, allDay) = (t, false)
            case .duration, .period: throw Unreadable()
            }
            var length = allDay ? 86_400 : 0
            if component.contains("DTEND") {
                var end = try like(single(component, "DTEND"), base)
                if allDay { end = ICalDateTime(wall: LocalDateTime(midnightOf: end.wall.date), zone: nil) }
                guard let seconds = end.seconds(since: base) else { throw Unreadable() }
                length = seconds
            } else if component.contains("DURATION") {
                guard case .duration(let seconds) = try single(component, "DURATION") else { throw Unreadable() }
                length = seconds
            }
            if allDay { length = max(length, 86_400) }
            return (base, max(length, 0), allDay)
        }

        /// Shown in the window: starts before it ends and ends after it starts; a zero-length
        /// event when it starts inside.
        static func overlaps(_ begin: ICalDateTime, _ length: Int, _ lo: ICalDateTime, _ hi: ICalDateTime) -> Bool {
            if length == 0 { return !precedes(begin, lo) && precedes(begin, hi) }
            return precedes(begin, hi) && precedes(lo, begin.adding(seconds: length))
        }

        /// Python's `occurrences`: the starts inside the window of DTSTART, RRULE and RDATE less
        /// EXDATE (dateutil's rruleset: in order, a time listed twice once), at most
        /// `maxOccurrences`. Throws `Unreadable` for a rule that cannot be read and for a
        /// series past `maxSteps`.
        func occurrences(_ component: ICalComponent, _ base: ICalDateTime, _ length: Int) throws -> [ICalDateTime] {
            let (lo, hi) = window(base)
            let rules = component.all("RRULE")
            if rules.isEmpty && !component.contains("RDATE") && !component.contains("EXDATE") {
                return Self.overlaps(base, length, lo, hi) ? [base] : []
            }
            guard rules.count <= 1 else { throw Unreadable() }  // a list to Python
            let rule = try rules.first.map { try RecurrenceRule($0.raw) }
            let bound = try rule?.until.map { try until($0, base) }
            /// RDATE or EXDATE, in order (a period is left out).
            func listed(_ name: String) throws -> [ICalDateTime] {
                var times: [ICalDateTime] = []
                for property in component.all(name) {
                    guard !property.isBroken else { throw Unreadable() }
                    for value in property.values where value != .period { times.append(try like(value, base)) }
                }
                return times
            }
            let included = try sorted([base] + listed("RDATE"))
            let excluded = try sorted(listed("EXDATE"))

            var found: [ICalDateTime] = []
            var steps = 0, nextIncluded = 0, nextExcluded = 0
            var last: ICalDateTime?
            /// One time of the set, in order; false when the walk is over.
            func take(_ time: ICalDateTime) throws -> Bool {
                if let last, same(last, time) { return true }
                last = time
                while nextExcluded < excluded.count && precedes(excluded[nextExcluded], time) { nextExcluded += 1 }
                if nextExcluded < excluded.count && same(excluded[nextExcluded], time) { return true }
                if steps >= ICal.maxSteps { throw Unreadable() }
                steps += 1
                if !precedes(time, hi) { return false }
                if Self.overlaps(time, length, lo, hi) {
                    found.append(time)
                    if found.count >= ICal.maxOccurrences { return false }
                }
                return true
            }
            // The rule's times and the listed ones merged as dateutil's heap merges them: a tie
            // goes to the side that did not just move on (to the rule at first), which decides
            // whose zone a time listed twice keeps.
            var going = true, first = true
            try rule?.forEach(from: base.wall, isPastUntil: { wall in
                bound.map { precedes($0, ICalDateTime(wall: wall, zone: base.zone)) } ?? false
            }) { wall in
                let time = ICalDateTime(wall: wall, zone: base.zone)
                var listedFirst = nextIncluded < included.count
                    && (first ? precedes(included[nextIncluded], time) : !precedes(time, included[nextIncluded]))
                first = false
                while listedFirst {
                    going = try take(included[nextIncluded])
                    nextIncluded += 1
                    if !going { return false }
                    listedFirst = nextIncluded < included.count && precedes(included[nextIncluded], time)
                }
                going = try take(time)
                return going
            }
            while going && nextIncluded < included.count {
                going = try take(included[nextIncluded])
                nextIncluded += 1
            }
            return found
        }

        /// What identifies an occurrence for RECURRENCE-ID: its date (all day) or its instant.
        enum Key: Hashable {
            case day(LocalDate)
            case instant(Date)
        }

        /// The occurrence an override's RECURRENCE-ID names. One that is not a date or time
        /// names none in an all-day series (Python compares it as it is) and makes a timed
        /// series unreadable; a repeated one makes either unreadable.
        func key(of override: ICalComponent, _ allDay: Bool) throws -> Key? {
            let ids = override.all("RECURRENCE-ID")
            guard ids.count == 1 else { throw Unreadable() }
            switch ids[0].isBroken ? nil : ids[0].value {
            case .date(let d)?:
                return allDay ? .day(d) : key(ICalDateTime(wall: LocalDateTime(midnightOf: d), zone: nil), false)
            case .dateTime(let t)?: return key(t, allDay)
            default:
                if allDay { return nil }
                throw Unreadable()
            }
        }

        func key(_ time: ICalDateTime, _ allDay: Bool) -> Key {
            if allDay { return .day(time.wall.date) }
            return .instant(ICalDateTime(wall: time.wall, zone: time.zone ?? floating).instant!)
        }

        /// One occurrence as an `Event`: all-day dates, or aware times (floating ones in the
        /// floating zone), the end `length` seconds later on the wall clock.
        func event(_ component: ICalComponent, _ begin: ICalDateTime, _ length: Int, _ allDay: Bool,
                   _ name: String, _ color: String) -> Event {
            let start: EventTime, end: EventTime
            if allDay {
                (start, end) = (.date(begin.wall.date), .date(begin.wall.adding(seconds: length).date))
            } else {
                let first = ICalDateTime(wall: begin.wall, zone: begin.zone ?? floating)
                let last = first.adding(seconds: length)
                (start, end) = (.dateTime(OffsetDateTime(first.wall, utcOffset: first.utcOffset!)),
                                .dateTime(OffsetDateTime(last.wall, utcOffset: last.utcOffset!)))
            }
            return Event(title: text(component, "SUMMARY"), start: start, end: end, allDay: allDay, calendar: name,
                         location: text(component, "LOCATION"), color: color)
        }

        // MARK: To-dos

        /// An open to-do; nil for a completed or cancelled one and one without a title. The due
        /// date of a DATE-TIME is read in the page's zone; the notes are the first line of
        /// DESCRIPTION that is not blank.
        func task(_ component: ICalComponent, _ name: String) throws -> AgendaTask? {
            let status = text(component, "STATUS").uppercased()
            if status == "COMPLETED" || status == "CANCELLED" || component.contains("COMPLETED") { return nil }
            let percent = component.all("PERCENT-COMPLETE")
            if percent.count == 1 && Int(text(percent[0])) == 100 { return nil }
            let title = text(component, "SUMMARY")
            if title.isEmpty { return nil }
            var due: LocalDate?
            if component.contains("DUE") {
                switch try single(component, "DUE") {
                case .date(let d): due = d
                case .dateTime(let t): due = t.instant.map { LocalDate($0, in: zone) } ?? t.wall.date
                case .duration, .period: throw Unreadable()  // Python keeps it as a due "date"
                }
            }
            let notes = text(component, "DESCRIPTION").unicodeScalars.split(whereSeparator: isLineBreak)
                .lazy.map { Note.strip($0) }.first { !$0.isEmpty } ?? ""
            return AgendaTask(title: title, due: due, listName: name, notes: notes)
        }
    }

    /// Python's `a < b` for two aware or two floating times: on the wall clock within one zone,
    /// else as instants.
    private static func precedes(_ a: ICalDateTime, _ b: ICalDateTime) -> Bool {
        (b.seconds(since: a) ?? 0) > 0
    }

    private static func same(_ a: ICalDateTime, _ b: ICalDateTime) -> Bool {
        b.seconds(since: a) == 0
    }

    /// Python's `list.sort()`: stable.
    private static func sorted(_ times: [ICalDateTime]) -> [ICalDateTime] {
        times.enumerated().sorted { a, b in
            precedes(a.element, b.element) || (!precedes(b.element, a.element) && a.offset < b.offset)
        }.map(\.element)
    }
}
