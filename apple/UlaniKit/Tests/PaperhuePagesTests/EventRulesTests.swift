import Foundation
import PaperhueAgenda
import Testing
@testable import PaperhuePages

/// The shared data rules of the calendar pages (shared/LAYOUTS.md 2): ports the helper tests of
/// python/tests/test_layouts.py.
@Suite struct EventRulesTests {
    static let tpe = TimeZone(secondsFromGMT: 8 * 3600)!
    static let day = LocalDate(year: 2026, month: 10, day: 12)!

    /// 2026-10-`day` hh:mm in Taipei.
    static func at(_ day: Int, _ hh: Int, _ mm: Int = 0) -> EventTime {
        .dateTime(OffsetDateTime(LocalDateTime(date: LocalDate(year: 2026, month: 10, day: day)!, hour: hh, minute: mm)!,
                                 utcOffset: 8 * 3600))
    }

    static func date(_ day: Int) -> EventTime { .date(LocalDate(year: 2026, month: 10, day: day)!) }

    static func ev(_ start: EventTime, _ end: EventTime, allDay: Bool = false, title: String = "x",
                   colour: String = "") -> Event {
        Event(title: title, start: start, end: end, allDay: allDay, color: colour)
    }

    @Test(arguments: [
        (ev(at(12, 10), at(12, 11, 30)), "10:00 – 11:30"),
        (ev(at(12, 23), at(13, 0)), "23:00 – 00:00"),
        (ev(at(12, 23), at(13, 1)), "23:00 – 隔天 01:00"),
        (ev(at(12, 20), at(14, 20)), "20:00 – 10月14日 20:00"),
        (ev(at(11, 22), at(12, 2)), "至 02:00"),
        (ev(at(12, 8), at(12, 8)), "08:00"),
        (ev(date(12), date(13), allDay: true), "全天"),
        (ev(date(10), date(13), allDay: true), "全天·第 3 天，共 3 天"),
        (ev(at(12, 0), at(13, 0)), "全天"),  // exactly 24 h counts as all day
    ])
    func rangeText(event: Event, text: String) {
        #expect(event.rangeText(on: Self.day, in: Self.tpe) == text)
    }

    @Test(arguments: [
        (ev(at(12, 9), at(12, 9, 30)), "09:00", "09:30"),
        (ev(at(12, 23), at(13, 1)), "23:00", "01:00"),  // early next morning: unambiguous
        (ev(at(12, 20), at(14, 9)), "20:00", "10/14"),
        (ev(at(11, 22), at(12, 2)), "至02:00", ""),
        (ev(at(12, 8), at(12, 8)), "08:00", ""),
        (ev(date(12), date(13), allDay: true), "全天", ""),
    ])
    func timeColumnLabels(event: Event, start: String, end: String) {
        #expect(event.startLabel(on: Self.day, in: Self.tpe) == start)
        #expect(event.endLabel(on: Self.day, in: Self.tpe) == end)
    }

    /// Python also ignores a naive sync time; the Swift model has none (AgendaData.fromJSON
    /// refuses a time without an offset).
    @Test(arguments: [
        (at(12, 7), at(12, 7)),
        (at(11, 23), at(12, 0)),  // synced the day before: start of today
        (nil, at(12, 0)),
        (EventTime.dateTime(OffsetDateTime(iso: "2026-10-11T23:30:00+00:00")!), at(12, 7, 30)),  // another zone
    ])
    func nowIsTheSyncTimeOnToday(fetched: EventTime?, now: EventTime) {
        let data = AgendaData(fetchedAt: fetched?.dateTime)
        #expect(data.now(today: Self.day, in: Self.tpe) == now.local(in: Self.tpe))
    }

    @Test func theSyncStampNamesTheYearOnlyWhenItDiffers() {
        let dec31 = OffsetDateTime(iso: "2025-12-31T22:00:00+08:00")!
        #expect(AgendaData(fetchedAt: dec31).syncText(today: Self.day, in: Self.tpe) == "更新於 2025/12/31")
        #expect(AgendaData(fetchedAt: dec31).syncText(today: LocalDate(year: 2025, month: 12, day: 31)!, in: Self.tpe)
                == "更新於 12/31")
        #expect(AgendaData().syncText(today: Self.day, in: Self.tpe) == "")
    }

    /// Ended, pending and covering events; a zero-length event is pending until it starts.
    @Test func splitsADay() {
        let events = [Self.ev(Self.date(12), Self.date(13), allDay: true), Self.ev(Self.at(12, 8), Self.at(12, 9)),
                      Self.ev(Self.at(12, 10), Self.at(12, 10)), Self.ev(Self.at(12, 9), Self.at(12, 11)),
                      Self.ev(Self.at(12, 0), Self.at(13, 0))]
        let now = LocalDateTime(date: Self.day, hour: 10, minute: 0)!
        let split = splitDay(events, Self.day, in: Self.tpe, now: now)
        #expect(split.allDay == [events[0], events[4]])
        #expect(split.pending == [events[2], events[3]])
        #expect(split.ended == 1)
        #expect(splitDay(events, Self.day, in: Self.tpe, now: nil).pending.count == 3)
    }

    /// The first event starting after today: by start, all-day first, then title by code points.
    @Test func nextEventAfterToday() {
        let a = Self.ev(Self.at(14, 9), Self.at(14, 10), title: "b")
        let b = Self.ev(Self.date(14), Self.date(15), allDay: true, title: "z")
        let c = Self.ev(Self.at(13, 0), Self.at(13, 1), title: "b")
        let d = Self.ev(Self.at(13, 0), Self.at(13, 1), title: "B")
        let e = Self.ev(Self.at(12, 23), Self.at(13, 2), title: "A")  // starts today: not next
        #expect(AgendaData(events: [a, b]).nextEvent(after: Self.day, in: Self.tpe) == b)
        #expect(AgendaData(events: [a, b, c, d, e]).nextEvent(after: Self.day, in: Self.tpe) == d)
        #expect(AgendaData(events: [e]).nextEvent(after: Self.day, in: Self.tpe) == nil)
    }

    /// Each calendar colour first, then repeats up to four dots, grouped by colour; "+" over four.
    @Test(arguments: [
        (["#f83a22", "#f83a22", "#4986e7", "#fad165", "#f83a22", "#16a765"], [PanelColour.red, .blue, .yellow, .green], true),
        (["#4986e7", "#4986e7", "#f83a22"], [.blue, .blue, .red], false),
        (["#f83a22", "#4986e7", "#f83a22", "#4986e7", "#f83a22"], [.red, .red, .blue, .blue], true),
        ([], [], false),
    ])
    func monthDots(colours: [String], dots: [PanelColour], more: Bool) {
        let events = colours.map { Self.ev(Self.at(12, 9), Self.at(12, 10), colour: $0) }
        #expect(MonthPage.dots(events) == (dots, more))
    }

    @Test func dayTexts() {
        let d = LocalDate(year: 2027, month: 3, day: 1)!
        #expect(DayText.md(d, reference: Self.day) == "2027年3月1日")
        #expect(DayText.md(Self.day, reference: Self.day) == "10月12日")
        #expect(DayText.weekdayLong(Self.day) == "星期一" && DayText.weekdayShort(d) == "週一")
        #expect(DayText.hm(LocalDateTime(date: d, hour: 7, minute: 5)!) == "07:05")
        #expect(DayText.more(3) == "還有 3 項")
        #expect(floorDivide(-1, 28) == -1 && floorDivide(-28, 28) == -1 && floorDivide(-29, 28) == -2
                && floorDivide(55, 28) == 1)
    }
}
