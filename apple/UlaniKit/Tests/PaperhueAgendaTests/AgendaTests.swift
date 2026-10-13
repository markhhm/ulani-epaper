import Foundation
import Testing
@testable import PaperhueAgenda

private func ev(_ title: String, _ start: EventTime, _ end: EventTime, allDay: Bool = false,
                calendar: String = "個人") -> Event {
    Event(title: title, start: start, end: end, allDay: allDay, calendar: calendar)
}

private func titles(_ events: [Event]) -> [String] { events.map(\.title) }

/// Titles as code points (String == treats canonically equivalent texts as equal; Python does not).
private func scalars(_ events: [Event]) -> [[UInt32]] { events.map { $0.title.unicodeScalars.map(\.value) } }

/// python/tests/test_agenda.py, plus the edge cases the Python reference decides.
@Suite struct AgendaTests {
    @Test func eventsOnADayAllDayFirstThenByStartTime() {
        let data = AgendaData(events: [
            ev("午餐", at(2026, 10, 12, 12, 0), at(2026, 10, 12, 13, 0)),
            ev("連假", .date(day(2026, 10, 10)), .date(day(2026, 10, 13)), allDay: true),  // end is exclusive
            ev("早會", at(2026, 10, 12, 9, 0), at(2026, 10, 12, 9, 30)),
            ev("明天", at(2026, 10, 13, 9, 0), at(2026, 10, 13, 10, 0)),
        ])
        #expect(titles(data.eventsOn(day(2026, 10, 12), in: tpe)) == ["連假", "早會", "午餐"])
        #expect(titles(data.eventsOn(day(2026, 10, 13), in: tpe)) == ["明天"])  // 連假 ended (exclusive)
    }

    @Test func timedEventsUseTheGivenTimeZone() {
        let utcLate = wall(2026, 10, 12, 17, 0).instant(in: utc)  // 01:00 on the 13th in Taipei
        let data = AgendaData(events: [ev("深夜", .at(utcLate, in: utc), .at(utcLate.addingTimeInterval(3600), in: utc))])
        #expect(data.eventsOn(day(2026, 10, 12), in: tpe).isEmpty)
        #expect(titles(data.eventsOn(day(2026, 10, 13), in: tpe)) == ["深夜"])
        #expect(titles(data.eventsOn(day(2026, 10, 12), in: utc)) == ["深夜"])
    }

    @Test func anEventSpanningMidnightShowsOnBothDays() {
        let data = AgendaData(events: [ev("跨夜", at(2026, 10, 12, 22, 0), at(2026, 10, 13, 2, 0))])
        #expect(!data.eventsOn(day(2026, 10, 12), in: tpe).isEmpty)
        #expect(!data.eventsOn(day(2026, 10, 13), in: tpe).isEmpty)
        #expect(data.eventsOn(day(2026, 10, 14), in: tpe).isEmpty)
    }

    @Test func openTasksSortedByDueDateThenUndated() {
        let data = AgendaData(tasks: [
            AgendaTask(title: "沒期限"), AgendaTask(title: "下週", due: day(2026, 10, 19)),
            AgendaTask(title: "昨天", due: day(2026, 10, 11)),
        ])
        #expect(data.sortedTasks().map(\.title) == ["昨天", "下週", "沒期限"])
    }

    @Test func jsonRoundTripKeepsDatesTimesAndZones() throws {
        let data = AgendaData(
            events: [ev("早會", at(2026, 10, 12, 9, 0), at(2026, 10, 12, 9, 30)),
                     ev("連假", .date(day(2026, 10, 10)), .date(day(2026, 10, 13)), allDay: true)],
            tasks: [AgendaTask(title: "繳費", due: day(2026, 10, 15), listName: "家務", notes: "電費")],
            fetchedAt: OffsetDateTime(wall(2026, 10, 12, 7, 0), utcOffset: 8 * 3600))
        let again = try AgendaData.fromJSON(Data(data.toJSON().utf8))
        #expect(again == data)
        #expect(again.events[0].start.dateTime?.utcOffset == 8 * 3600)
        #expect(again.events[0].start.dateTime?.iso == "2026-10-12T09:00:00+08:00")
    }

    @Test func fromJSONToleratesMissingOptionalFields() throws {
        let text = #"{"events": [{"title": "x", "start": "2026-10-12", "end": "2026-10-13", "all_day": true}], "tasks": [{"title": "y"}]}"#
        let data = try AgendaData.fromJSON(Data(text.utf8))
        #expect(data.events[0].calendar == "" && data.tasks[0].due == nil && data.fetchedAt == nil)
        #expect(data.events[0].color == "")
        #expect(data.events[0].location == "" && data.tasks[0].listName == "" && data.tasks[0].notes == "")
    }

    // test_local_time_zone_follows_the_os / test_local_time_zone_handles_daylight_saving: the
    // zones are TimeZone values, DST-aware for every instant.
    @Test(arguments: [TimeZone.current, TimeZone(identifier: "America/New_York")!, TimeZone(identifier: "Asia/Taipei")!,
                      TimeZone(identifier: "Australia/Lord_Howe")!])
    func zonesFollowTheirRulesForEveryInstant(zone: TimeZone) {
        for month in 1...12 {
            let noon = wall(2026, month, 15, 12, 0).instant(in: utc)
            #expect(OffsetDateTime(noon, in: zone).utcOffset == zone.secondsFromGMT(for: noon))
            let midnight = day(2026, month, 15).midnight(in: zone)
            #expect(LocalDateTime(midnight, in: zone) == wall(2026, month, 15, 0, 0))
            #expect(LocalDate(midnight, in: zone) == day(2026, month, 15))
        }
    }

    @Test func daylightSaving() throws {
        let ny = try zone("America/New_York")
        #expect(OffsetDateTime(day(2026, 1, 15).midnight(in: ny), in: ny).utcOffset == -5 * 3600)
        #expect(OffsetDateTime(day(2026, 7, 15).midnight(in: ny), in: ny).utcOffset == -4 * 3600)
    }

    // test_local_time_zone_never_fails_outside_the_os_range
    @Test(arguments: [1, 1900, 1969, 3001, 9999])
    func zonesWorkFarFromToday(year: Int) {
        for zone in [TimeZone.current, TimeZone(identifier: "America/New_York")!] {
            let noon = wall(year, 6, 1, 12, 0)
            let instant = noon.instant(in: zone)
            #expect(LocalDateTime(instant, in: zone) == noon)
            #expect(abs(OffsetDateTime(instant, in: zone).utcOffset) < 86_400)
        }
    }

    @Test func eventColourRoundTrips() throws {
        let data = AgendaData(events: [Event(title: "x", start: .date(day(2026, 10, 12)), end: .date(day(2026, 10, 13)),
                                             allDay: true, color: "#4986e7")])
        #expect(try AgendaData.fromJSON(Data(data.toJSON().utf8)).events[0].color == "#4986e7")
    }

    // MARK: Beyond the Python tests

    @Test func zeroLengthEventsShowOnTheDayTheyHappen() {
        let data = AgendaData(events: [
            ev("午夜", at(2026, 10, 13, 0, 0), at(2026, 10, 13, 0, 0)),
            ev("繳費", at(2026, 10, 12, 8, 0), at(2026, 10, 12, 8, 0)),
        ])
        #expect(titles(data.eventsOn(day(2026, 10, 12), in: tpe)) == ["繳費"])
        #expect(titles(data.eventsOn(day(2026, 10, 13), in: tpe)) == ["午夜"])
    }

    @Test func endsAreExclusive() {
        let data = AgendaData(events: [
            ev("到午夜", at(2026, 10, 12, 22, 0), at(2026, 10, 13, 0, 0)),
            ev("一天", .date(day(2026, 10, 12)), .date(day(2026, 10, 13)), allDay: true),
        ])
        #expect(titles(data.eventsOn(day(2026, 10, 12), in: tpe)) == ["一天", "到午夜"])
        #expect(data.eventsOn(day(2026, 10, 13), in: tpe).isEmpty)
        #expect(data.eventsOn(day(2026, 10, 11), in: tpe).isEmpty)
    }

    @Test func titlesCompareAsCodePoints() {
        let all = { (t: String) in ev(t, .date(day(2026, 10, 12)), .date(day(2026, 10, 13)), allDay: true) }
        // Python: "é" < "f" < "é" (no normalisation), "\u{FF21}" < "\u{1F600}" (not UTF-16).
        let data = AgendaData(events: [all("\u{E9}"), all("f"), all("e\u{301}"), all("\u{1F600}"), all("\u{FF21}")])
        #expect(scalars(data.eventsOn(day(2026, 10, 12), in: tpe)) == [[0x65, 0x301], [0x66], [0xE9], [0xFF21], [0x1F600]])
        #expect(PaperhueAgenda.codePointsPrecede("e\u{301}", "\u{E9}"))
        #expect(!PaperhueAgenda.codePointsPrecede("\u{E9}", "e\u{301}"))
        #expect(PaperhueAgenda.codePointsPrecede("\u{FF21}", "\u{1F600}"))
        #expect(PaperhueAgenda.codePointsPrecede("", "a"))
        #expect(PaperhueAgenda.codePointsPrecede("Z", "a"))
        #expect(!PaperhueAgenda.codePointsPrecede("a", "a"))
        #expect(PaperhueAgenda.codePointsPrecede("ab", "abc"))
        #expect(PaperhueAgenda.compareCodePoints("\r\n", "\r") == 1)  // one Character, two code points
    }

    @Test func equalKeysKeepTheirOrder() {
        let data = AgendaData(events: [
            Event(title: "同", start: at(2026, 10, 12, 9, 0), end: at(2026, 10, 12, 10, 0), location: "一"),
            Event(title: "同", start: at(2026, 10, 12, 9, 0), end: at(2026, 10, 12, 11, 0), location: "二"),
            Event(title: "同", start: at(2026, 10, 12, 9, 0), end: at(2026, 10, 12, 9, 30), location: "三"),
        ], tasks: [
            AgendaTask(title: "同", notes: "一"), AgendaTask(title: "同", notes: "二"),
            AgendaTask(title: "同", due: day(2026, 10, 12), notes: "三"),
        ])
        #expect(data.eventsOn(day(2026, 10, 12), in: tpe).map(\.location) == ["一", "二", "三"])
        #expect(data.sortedTasks().map(\.notes) == ["三", "一", "二"])
    }

    @Test func wallClockOrderInTheRepeatedHour() throws {
        // New York repeats 01:00-02:00 on 2026-11-01. Python compares the local wall times
        // (both values share the page's tzinfo): 01:15 EST sorts before 01:45 EDT.
        let ny = try zone("America/New_York")
        let edt = instant(micros: 1_793_511_900_000_000), est = instant(micros: 1_793_513_700_000_000)
        let a = ev("A", .at(edt, in: ny), .at(edt.addingTimeInterval(300), in: ny))  // 01:45 EDT
        let b = ev("B", .at(est, in: ny), .at(est.addingTimeInterval(300), in: ny))  // 01:15 EST
        #expect(titles(AgendaData(events: [a, b]).eventsOn(day(2026, 11, 1), in: ny)) == ["B", "A"])
        #expect(a.localStart(in: ny) == wall(2026, 11, 1, 1, 45))
        #expect(b.localStart(in: ny) == wall(2026, 11, 1, 1, 15))
        #expect(a.start.dateTime?.utcOffset == -4 * 3600 && b.start.dateTime?.utcOffset == -5 * 3600)
    }

    @Test func localRangeAndOverlaps() {
        let allDay = ev("假", .date(day(2026, 10, 10)), .date(day(2026, 10, 13)), allDay: true)
        let range = allDay.localRange(in: tpe)
        #expect(range.start == LocalDateTime(midnightOf: day(2026, 10, 10)))
        #expect(range.end == LocalDateTime(midnightOf: day(2026, 10, 13)))
        #expect(allDay.overlaps(day(2026, 10, 12), in: tpe))
        #expect(!allDay.overlaps(day(2026, 10, 13), in: tpe))
        #expect(EventTime.date(day(2026, 10, 12)).local(in: utc) == wall(2026, 10, 12, 0, 0))
        #expect(at(2026, 10, 12, 9, 0).local(in: utc) == wall(2026, 10, 12, 1, 0))
        #expect(at(2026, 10, 12, 9, 0).date == nil)
        #expect(EventTime.date(day(2026, 10, 12)).date == day(2026, 10, 12))
        #expect(EventTime.date(day(2026, 10, 12)).instant == nil)
        #expect(at(2026, 10, 12, 9, 0).instant == wall(2026, 10, 12, 1, 0).instant(in: utc))
        #expect(at(2026, 10, 12, 9, 0).calendarDate == day(2026, 10, 12))
        // A Python dataclass compares aware datetimes as instants: the offset is not part of it.
        #expect(at(2026, 10, 12, 9, 0) == at(2026, 10, 12, 1, 0, utc))
        #expect(EventTime.date(day(2026, 10, 12)) != at(2026, 10, 12, 0, 0))
    }

    @Test func allDayFlagDecidesHowValuesAreRead() {
        // Python's from_json takes `all_day` as given: an all-day event with date-times uses
        // their dates (in their own offsets), as datetime.combine does.
        let odd = ev("x", at(2026, 10, 12, 23, 30), at(2026, 10, 13, 0, 30), allDay: true)
        #expect(odd.localRange(in: utc) == (LocalDateTime(midnightOf: day(2026, 10, 12)),
                                             LocalDateTime(midnightOf: day(2026, 10, 13))))
        #expect(odd.overlaps(day(2026, 10, 12), in: utc) && !odd.overlaps(day(2026, 10, 13), in: utc))
    }

    @Test func differentialCasesMatchPython() throws {
        let cases = try Expectations.load().cases
        #expect(cases.count == 8)
        for c in cases {
            let data = try AgendaData.fromJSON(Data(c.data.utf8))
            let z = try zone(c.zone)
            for (iso, indices) in c.eventsOn {
                let got = data.eventsOn(try day(iso: iso), in: z)
                let want = indices.map { data.events[$0] }
                #expect(got == want, "\(c.name) \(iso)")
                #expect(scalars(got) == scalars(want), "\(c.name) \(iso)")
            }
            let tasks = data.sortedTasks()
            let wantTasks = c.sortedTasks.map { data.tasks[$0] }
            #expect(tasks == wantTasks, "\(c.name)")
            #expect(tasks.map { $0.title.unicodeScalars.map(\.value) }
                    == wantTasks.map { $0.title.unicodeScalars.map(\.value) }, "\(c.name)")
        }
    }
}
