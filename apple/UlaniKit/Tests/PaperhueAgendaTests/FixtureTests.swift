import Foundation
import Testing
@testable import PaperhueAgenda

/// The calendar page fixtures in shared/layouts/agenda/, read as python/tests/test_layouts.py
/// reads them, and AgendaData's JSON.
@Suite struct FixtureTests {
    @Test(arguments: Repo.agendaFixtureNames)
    func everyAgendaFixtureLoads(name: String) throws {
        let fixture = try AgendaFixture(contentsOf: Repo.agendaFixture(name))
        #expect(fixture.today == day(2026, 10, 12))
        #expect(fixture.utcOffset == "+08:00" && fixture.zone.secondsFromGMT() == 8 * 3600)
        let counts = ["sample": (23, 7), "empty": (0, 0), "busy": (83, 33), "midday": (23, 7)]
        let (events, tasks) = try #require(counts[name])
        #expect(fixture.data.events.count == events)
        #expect(fixture.data.tasks.count == tasks)
        let synced = name == "midday" ? wall(2026, 10, 12, 13, 30) : wall(2026, 10, 12, 7, 0)
        #expect(fixture.data.fetchedAt == OffsetDateTime(synced, utcOffset: 8 * 3600))
        #expect(fixture.data.fetchedAt?.iso == synced.iso + "+08:00")
        for e in fixture.data.events {
            switch (e.allDay, e.start, e.end) {
            case (true, .date, .date), (false, .dateTime, .dateTime): break
            default: Issue.record("\(name): all-day flag and value kinds disagree")
            }
        }
    }

    @Test(arguments: Repo.agendaFixtureNames)
    func agendaFixturesMatchPython(name: String) throws {
        let expected = try #require(try Expectations.load().fixtures[name])
        let data = try AgendaFixture(contentsOf: Repo.agendaFixture(name)).data
        #expect(expected.eventsOn.count == 6)
        for (zoneName, days) in expected.eventsOn {
            let z = try zone(zoneName)
            #expect(days.count == 52)
            for (iso, indices) in days {
                let got = data.eventsOn(try day(iso: iso), in: z)
                #expect(got == indices.map { data.events[$0] }, "\(name) \(zoneName) \(iso)")
            }
        }
        #expect(data.sortedTasks() == expected.sortedTasks.map { data.tasks[$0] }, "\(name)")
        #expect(data.toJSON() == expected.toJSON, "\(name)")
    }

    @Test func busyFixtureEdgeCases() throws {
        let data = try AgendaFixture(contentsOf: Repo.agendaFixture("busy")).data
        let parking = try #require(data.events.first { $0.title == "繳停車費" })
        #expect(parking.start == parking.end)  // zero-length
        #expect(data.eventsOn(day(2026, 10, 12), in: tpe).contains(parking))
        #expect(!data.eventsOn(day(2026, 10, 11), in: tpe).contains(parking))
        let airport = try #require(data.events.first { $0.title == "機場接機" })  // 23:00 -> 01:00
        #expect(data.eventsOn(day(2026, 10, 15), in: tpe).contains(airport))
        #expect(data.eventsOn(day(2026, 10, 16), in: tpe).contains(airport))
        #expect(!data.eventsOn(day(2026, 10, 17), in: tpe).contains(airport))
        let trip = try #require(data.events.first { $0.title == "墾丁三日遊" })  // 10-10 ..< 10-13
        #expect(trip.start == .date(day(2026, 10, 10)) && trip.end == .date(day(2026, 10, 13)))
        #expect(data.eventsOn(day(2026, 10, 12), in: tpe).contains(trip))
        #expect(!data.eventsOn(day(2026, 10, 13), in: tpe).contains(trip))
        let today = data.eventsOn(day(2026, 10, 12), in: tpe)
        let firstTimed = try #require(today.firstIndex { !$0.allDay })
        #expect(today[..<firstTimed].allSatisfy(\.allDay) && today[firstTimed...].allSatisfy { !$0.allDay })
    }

    // MARK: AgendaData JSON

    @Test func toJSONMatchesPython() throws {
        let expected = try Expectations.load().toJSON
        let data = try AgendaData.fromJSON(Data(expected.input.utf8))
        #expect(data.toJSON() == expected.output)
        #expect(try AgendaData.fromJSON(Data(expected.output.utf8)) == data)
        #expect(AgendaData().toJSON() == expected.empty)
        // all_day is Python's bool() of the value: 1 is true, and the date-times stay date-times.
        #expect(data.events[2].allDay && data.events[2].start.dateTime?.utcOffset == 5 * 3600 + 45 * 60)
        #expect(data.events[0].end.dateTime?.iso == "2026-10-12T10:00:00-03:30")
        #expect(data.tasks[1].due == nil)
    }

    @Test func nullsAndOddValues() throws {
        let nulls = #"{"today": "2026-10-12", "utc_offset": "+08:00", "events": [{"title": "x", "start": "2026-10-12T09:00:00+08:00", "end": "2026-10-12T10:00:00+08:00", "all_day": null, "calendar": null, "location": null, "color": null}], "tasks": [{"title": "y", "due": "", "list_name": null, "notes": null}], "fetched_at": ""}"#
        let fixture = try AgendaFixture(json: Data(nulls.utf8))
        #expect(fixture.data.events[0].allDay == false && fixture.data.events[0].calendar == "")
        #expect(fixture.data.tasks[0].due == nil && fixture.data.tasks[0].listName == "" && fixture.data.fetchedAt == nil)
        let bare = try AgendaFixture(json: Data(#"{"today": "2026-10-12", "utc_offset": "-0330"}"#.utf8))
        #expect(bare.data == AgendaData() && bare.zone.secondsFromGMT() == -12_600)
        let z = try AgendaFixture(json: Data(#"{"today": "2026-10-12", "utc_offset": "Z"}"#.utf8))
        #expect(z.zone.secondsFromGMT() == 0)
    }

    @Test func badFixturesAreRefusedWithoutEchoingTheirContent() throws {
        let cases: [(String, String)] = [
            (#"{"utc_offset": "+08:00"}"#, "today"),
            (#"{"today": "2026-10-12"}"#, "utc_offset"),
            (#"{"today": "2026-10-32", "utc_offset": "+08:00"}"#, "today"),
            (#"{"today": "2026-10-12", "utc_offset": "UTC+8"}"#, "utc_offset"),
            (#"{"today": "2026-10-12", "utc_offset": "+08"}"#, "utc_offset"),
            (#"{"today": "2026-10-12", "utc_offset": "+24:00"}"#, "utc_offset"),
            (#"{"today": "2026-10-12", "utc_offset": "+08:00", "events": [{"start": "2026-10-12", "end": "2026-10-13"}]}"#,
             "events[0].title"),
            (#"{"today": "2026-10-12", "utc_offset": "+08:00", "events": [{"title": "秘密會議", "start": "2026-13-12", "end": "2026-10-13", "all_day": true}]}"#,
             "events[0].start"),
            (#"{"today": "2026-10-12", "utc_offset": "+08:00", "events": [{"title": "秘密會議", "start": "2026-10-12T09:00:00", "end": "2026-10-12T10:00:00"}]}"#,
             "events[0].start"),
            (#"{"today": "2026-10-12", "utc_offset": "+08:00", "events": [{"title": "秘密會議", "start": "2026-10-12", "end": 5}]}"#,
             "events[0].end"),
            (#"{"today": "2026-10-12", "utc_offset": "+08:00", "events": [{"title": "秘密會議", "start": "2026-10-12", "end": "2026-10-13", "location": 3}]}"#,
             "events[0].location"),
            (#"{"today": "2026-10-12", "utc_offset": "+08:00", "events": ["秘密會議"]}"#, "events[0]"),
            (#"{"today": "2026-10-12", "utc_offset": "+08:00", "events": {"秘密會議": 1}}"#, "events"),
            (#"{"today": "2026-10-12", "utc_offset": "+08:00", "tasks": [{"title": "秘密會議", "due": "2026-10-12T09:00:00Z"}]}"#,
             "tasks[0].due"),
            (#"{"today": "2026-10-12", "utc_offset": "+08:00", "tasks": [{"title": 7}]}"#, "tasks[0].title"),
            (#"{"today": "2026-10-12", "utc_offset": "+08:00", "fetched_at": "2026-10-12T07:00:00"}"#, "fetched_at"),
            (#"["秘密會議"]"#, "fixture"),
            (#"{"today": "2026-10-12", "#, "fixture"),
        ]
        for (json, field) in cases {
            do {
                _ = try AgendaFixture(json: Data(json.utf8))
                Issue.record("accepted: \(field)")
            } catch let error as FixtureError {
                #expect(error.description.hasPrefix(field), "\(error.description)")
                #expect(!error.description.contains("秘密"), "\(error.description)")
                #expect(!error.description.contains("2026-1"), "\(error.description)")
            }
        }
    }
}
