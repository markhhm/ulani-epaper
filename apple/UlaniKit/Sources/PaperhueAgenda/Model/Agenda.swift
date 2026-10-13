import Foundation

// The calendar data model, as in python/src/ulani_epaper/agenda.py. Kept in memory only:
// nothing from a calendar is written to disk or logs.

/// When an event starts or ends: a local date (all-day events) or an instant with its UTC
/// offset (timed events).
public enum EventTime: Hashable, Sendable {
    case date(LocalDate)
    case dateTime(OffsetDateTime)

    /// A timed value: `instant` written in `zone`'s offset at that instant.
    public static func at(_ instant: Date, in zone: TimeZone) -> EventTime {
        .dateTime(OffsetDateTime(instant, in: zone))
    }

    /// The wall-clock time in `zone`: a date is its midnight, an instant its local time
    /// (Python: `datetime.combine(date, time(), zone)` / `value.astimezone(zone)`).
    public func local(in zone: TimeZone) -> LocalDateTime {
        switch self {
        case .date(let d): LocalDateTime(midnightOf: d)
        case .dateTime(let t): t.local(in: zone)
        }
    }

    /// The calendar date: the date itself, or the wall-clock date in the value's own offset
    /// (what Python's `datetime.combine(value, time(), zone)` takes from a datetime).
    public var calendarDate: LocalDate {
        switch self {
        case .date(let d): d
        case .dateTime(let t): t.wallClock.date
        }
    }

    public var date: LocalDate? { if case .date(let d) = self { d } else { nil } }
    public var dateTime: OffsetDateTime? { if case .dateTime(let t) = self { t } else { nil } }
    public var instant: Date? { dateTime?.instant }
}

/// One occurrence of a calendar event.
///
/// All-day events have `.date` values with an exclusive end (iCalendar's convention, at
/// least one day); timed events have `.dateTime` values (end exclusive, may equal the start).
/// Equal when every field is equal, instants compared as instants (Python's dataclass `==`).
public struct Event: Hashable, Sendable {
    public var title: String
    public var start: EventTime
    /// Exclusive.
    public var end: EventTime
    public var allDay: Bool
    /// The calendar (feed) name.
    public var calendar: String
    public var location: String
    /// The calendar's colour, "#rrggbb"; "" = none.
    public var color: String

    public init(title: String, start: EventTime, end: EventTime, allDay: Bool = false, calendar: String = "",
                location: String = "", color: String = "") {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
        self.color = color
    }

    /// Start and end as wall-clock times in `zone` (Python: `Event._range`, `layouts._local`).
    /// All-day: local midnights of the dates. Timed: the instants' local times (a `.date` in a
    /// timed event, which Python cannot handle, counts as its midnight).
    public func localRange(in zone: TimeZone) -> (start: LocalDateTime, end: LocalDateTime) {
        if allDay {
            return (LocalDateTime(midnightOf: start.calendarDate), LocalDateTime(midnightOf: end.calendarDate))
        }
        return (start.local(in: zone), end.local(in: zone))
    }

    /// The local start (Python: `Event.start_in`).
    public func localStart(in zone: TimeZone) -> LocalDateTime { localRange(in: zone).start }

    /// Touches `day` in `zone`: starts before the day ends and ends after it starts; a
    /// zero-length event shows on the day it happens. Compared on the wall clock, as Python
    /// compares aware datetimes that share a tzinfo.
    public func overlaps(_ day: LocalDate, in zone: TimeZone) -> Bool {
        let (s, e) = localRange(in: zone)
        return Self.touches(start: s, end: e, day: day)
    }

    static func touches(start s: LocalDateTime, end e: LocalDateTime, day: LocalDate) -> Bool {
        let dayStart = LocalDateTime(midnightOf: day)
        let dayEnd = LocalDateTime(midnightOf: day.adding(days: 1))
        if s == e {  // zero-length event: show on the day it happens
            return dayStart <= s && s < dayEnd
        }
        return s < dayEnd && e > dayStart
    }
}

/// An open to-do (completed and cancelled ones are left out when parsing). Python: `Task`.
public struct AgendaTask: Hashable, Sendable {
    public var title: String
    public var due: LocalDate?
    /// The list (feed) name.
    public var listName: String
    public var notes: String

    public init(title: String, due: LocalDate? = nil, listName: String = "", notes: String = "") {
        self.title = title
        self.due = due
        self.listName = listName
        self.notes = notes
    }
}

/// Everything the calendar pages draw: events, open to-dos and when they were fetched.
public struct AgendaData: Hashable, Sendable {
    public var events: [Event]
    public var tasks: [AgendaTask]
    public var fetchedAt: OffsetDateTime?

    public init(events: [Event] = [], tasks: [AgendaTask] = [], fetchedAt: OffsetDateTime? = nil) {
        self.events = events
        self.tasks = tasks
        self.fetchedAt = fetchedAt
    }

    /// Events touching `day` (local to `zone`): all-day first, then by local start time, then
    /// by title (code points); ties keep their order (Python's stable sort).
    public func eventsOn(_ day: LocalDate, in zone: TimeZone) -> [Event] {
        var hits: [(index: Int, start: LocalDateTime, event: Event)] = []
        for (index, event) in events.enumerated() {
            let (s, e) = event.localRange(in: zone)
            if Event.touches(start: s, end: e, day: day) {
                hits.append((index, s, event))
            }
        }
        hits.sort { a, b in
            if a.event.allDay != b.event.allDay { return a.event.allDay }
            if a.start != b.start { return a.start < b.start }
            let titles = PaperhueAgenda.compareCodePoints(a.event.title, b.event.title)
            return titles != 0 ? titles < 0 : a.index < b.index
        }
        return hits.map(\.event)
    }

    /// Open tasks: dated ones by due date first, then the undated ones; ties by title (code
    /// points), then their order.
    public func sortedTasks() -> [AgendaTask] {
        tasks.enumerated().sorted { a, b in
            switch (a.element.due, b.element.due) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let titles = PaperhueAgenda.compareCodePoints(a.element.title, b.element.title)
                return titles != 0 ? titles < 0 : a.offset < b.offset
            }
        }.map(\.element)
    }
}
