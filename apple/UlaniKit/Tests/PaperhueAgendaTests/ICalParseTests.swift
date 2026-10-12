import Foundation
import Testing
@testable import PaperhueAgenda

/// Reading whole calendars as python/src/ulani_epaper/ical.py `parse` does: every case of
/// shared/vectors/ical-vectors.json, the reference's results in Differential/parse-expectations.json
/// (make_parse_expectations.py: the shared .ics files in a DST zone and recurrence rules against
/// dateutil), and the inline cases of python/tests/test_ical.py.
@Suite struct ICalParseTests {
    @Test func sharedVectors() throws {
        let url = Repo.url("shared/vectors/ical-vectors.json")
        let vectors = try JSONDecoder().decode(ICalVectors.self, from: Data(contentsOf: url))
        let zone = try zone(vectors.utcOffset)
        #expect(vectors.cases.count == 6)
        for c in vectors.cases {
            let data = try Data(contentsOf: Repo.url("shared/vectors/ical/" + c.file))
            let start = try #require(OffsetDateTime(iso: c.window[0])).instant
            let end = try #require(OffsetDateTime(iso: c.window[1])).instant
            let feed = try ICal.parse(data, start: start, end: end, zone: zone)
            let label = "\(c.file) \(c.window[0])"
            #expect(feed.name == c.name && feed.skipped == c.skipped, "\(label)")
            let events = feed.events.map { e in
                ICalVectors.Event(title: e.title, start: Self.text(e.start, in: zone), end: Self.text(e.end, in: zone),
                                  allDay: e.allDay, location: e.location)
            }.sorted { codePointOrder(($0.start, $0.title), ($1.start, $1.title)) }
            #expect(events == c.events, "\(label)")
            let tasks = feed.tasks.map { ICalVectors.Task(title: $0.title, due: $0.due?.iso, notes: $0.notes) }
                .sorted { PaperhueAgenda.codePointsPrecede($0.title, $1.title) }
            #expect(tasks == c.tasks, "\(label)")
        }
    }

    @Test func sharedFilesInADaylightSavingZone() throws {
        let cases = try ParseExpectations.load().files
        #expect(cases.count == 6)
        for c in cases {
            let got = try c.parse(Data(contentsOf: Repo.url(c.file ?? "")), name: c.name ?? "", color: c.color ?? "")
            #expect(got == c.result, "\(c.file) \(c.window)")
        }
    }

    @Test func recurrenceAsDateutilExpandsIt() throws {
        let cases = try ParseExpectations.load().rules
        #expect(cases.count == 34)
        for c in cases {
            #expect(try c.parse(Data((c.ics ?? "").utf8)) == c.result, "\(c.name ?? "")")
        }
    }

    /// Rules Python expands and the Swift side does not (apple/DEVELOPING.md): the event is skipped
    /// and counted, never shown wrongly.
    @Test(arguments: ["FREQ=HOURLY;COUNT=3", "FREQ=MINUTELY;INTERVAL=30", "FREQ=SECONDLY;COUNT=2",
                      "FREQ=YEARLY;BYWEEKNO=20", "FREQ=YEARLY;BYYEARDAY=100", "FREQ=DAILY;BYHOUR=9,17",
                      "FREQ=DAILY;BYMINUTE=30", "FREQ=DAILY;BYSECOND=0", "FREQ=DAILY;INTERVAL=0"])
    func unsupportedRulesSkipTheEvent(rule: String) throws {
        let feed = try parse(event("DTSTART;TZID=Asia/Taipei:20261012T090000", "RRULE:" + rule))
        #expect(feed.events.isEmpty && feed.skipped == 1)
    }

    // MARK: python/tests/test_ical.py

    @Test func windowIsHalfOpenAndKeepsOverlappingEvents() throws {
        let data = try Data(contentsOf: Repo.url("shared/vectors/ical/google.ics"))
        let feed = try ICal.parse(data, start: Self.midnight(2026, 10, 11), end: Self.midnight(2026, 10, 12), zone: tpe)
        #expect(feed.events.map(\.title) == ["墾丁三日遊"])
    }

    @Test func feedNameColourAndLocationGoOntoEvents() throws {
        let data = try Data(contentsOf: Repo.url("shared/vectors/ical/google.ics"))
        let feed = try ICal.parse(data, start: Self.midnight(2026, 10, 1), end: Self.midnight(2026, 11, 1), zone: tpe,
                                  name: "我的", color: "#ff0000")
        let standup = try #require(feed.events.first { $0.title == "晨會" })
        #expect(standup.calendar == "我的" && standup.color == "#ff0000" && standup.location == "3F 會議室")
        #expect(standup.start.dateTime?.utcOffset == 8 * 3600)
        #expect(feed.name == "我的")
    }

    @Test func eventsTheOwnerDeclinedAreLeftOut() throws {
        let feed = try parse(Self.declined, owner: "me@gmail.com")
        #expect(feed.events.map { "\($0.title) \($0.start.calendarDate.day)" }.sorted()
                == ["accepted 20", "weekly, but declined once 19", "weekly, but declined once 5"])
    }

    @Test func withoutAnOwnerNothingIsJudgedDeclined() throws {
        #expect(try parse(Self.declined).events.count == 5)
    }

    @Test func rdateWithoutRRuleAddsDates() throws {
        let feed = try parse(event("DTSTART:20261001T020000Z", "RDATE:20261008T020000Z,20261015T020000Z"))
        #expect(starts(feed) == [at(2026, 10, 1, 10, 0), at(2026, 10, 8, 10, 0), at(2026, 10, 15, 10, 0)])
    }

    @Test func exdateCanRemoveDTStartOfAnRDateSet() throws {
        let feed = try parse(event("DTSTART:20261001T020000Z", "RDATE:20261008T020000Z", "EXDATE:20261001T020000Z"))
        #expect(starts(feed) == [at(2026, 10, 8, 10, 0)])
    }

    @Test func dtstartCountsEvenWhenTheRuleDoesNotMatchIt() throws {
        let feed = try parse(event("DTSTART:20261001T010000Z", "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=3"))
        #expect(starts(feed) == [at(2026, 10, 1, 9, 0), at(2026, 10, 5, 9, 0), at(2026, 10, 12, 9, 0),
                                 at(2026, 10, 19, 9, 0)])
    }

    @Test func customTimeZonesDoNotLeakBetweenFeeds() throws {
        func feed(_ offset: String) throws -> ParsedFeed {
            try parse(Self.calendar("BEGIN:VTIMEZONE", "TZID:Customized Time Zone", "BEGIN:STANDARD",
                                    "DTSTART:19700101T000000", "TZOFFSETFROM:\(offset)", "TZOFFSETTO:\(offset)",
                                    "END:STANDARD", "END:VTIMEZONE", "BEGIN:VEVENT", "UID:u", "SUMMARY:x",
                                    "DTSTART;TZID=Customized Time Zone:20261012T090000", "DURATION:PT1H", "END:VEVENT"))
        }
        #expect(starts(try feed("-0500")) == [at(2026, 10, 12, 22, 0)])
        #expect(starts(try feed("+0100")) == [at(2026, 10, 12, 16, 0)])
    }

    @Test func aRepeatedSummaryUsesTheFirst() throws {
        let feed = try parse(Self.calendar("BEGIN:VEVENT", "UID:u", "SUMMARY:一", "SUMMARY:二",
                                           "DTSTART;VALUE=DATE:20261012", "END:VEVENT"))
        #expect(feed.events.map(\.title) == ["一"])
    }

    @Test func floatingTimesUseTheGivenZoneWithoutXWRTimezone() throws {
        let feed = try parse(event("DTSTART:20261020T080000", "DTEND:20261020T090000"))
        #expect(feed.events.first?.start == at(2026, 10, 20, 8, 0))
    }

    @Test func aBrokenEventIsSkippedNotFatal() throws {
        let feed = try parse(Self.calendar("BEGIN:VEVENT", "UID:bad", "SUMMARY:bad", "DTSTART:20261020T080000",
                                           "RRULE:FREQ=SOMETIMES", "END:VEVENT", "BEGIN:VEVENT", "UID:ok",
                                           "SUMMARY:ok", "DTSTART;VALUE=DATE:20261020", "END:VEVENT"))
        #expect(feed.events.map(\.title) == ["ok"] && feed.skipped == 1)
    }

    @Test(arguments: ["", "<html>not a calendar</html>", "BEGIN:VCARD\r\nEND:VCARD\r\n"])
    func notACalendar(text: String) {
        #expect(throws: ICalError.self) { try parse(Data(text.utf8)) }
    }

    /// Python skips this one as a runaway; the Swift side skips MINUTELY rules outright. Same result.
    @Test func aRunawayRuleIsSkippedQuickly() throws {
        let feed = try parse(series("19700101T070000", "FREQ=MINUTELY;INTERVAL=30"))
        #expect(feed.events.isEmpty && feed.skipped == 1)
    }

    @Test func aDailyEventSinceYearsAgoIsExpanded() throws {
        let feed = try parse(series("20100101T070000", "FREQ=DAILY"))
        #expect(feed.events.count == 31 && feed.skipped == 0)
    }

    // MARK: -

    static let declined = calendar(
        "BEGIN:VEVENT", "UID:a", "SUMMARY:accepted", "DTSTART:20261020T010000Z",
        "ATTENDEE;PARTSTAT=ACCEPTED:mailto:Me@Gmail.com", "END:VEVENT",
        "BEGIN:VEVENT", "UID:b", "SUMMARY:declined", "DTSTART:20261021T010000Z",
        "ATTENDEE;CN=Someone;PARTSTAT=ACCEPTED:mailto:someone@example.com",
        "ATTENDEE;PARTSTAT=DECLINED:mailto:me@gmail.com", "END:VEVENT",
        "BEGIN:VEVENT", "UID:c", "SUMMARY:weekly, but declined once", "DTSTART:20261005T010000Z",
        "RRULE:FREQ=WEEKLY;COUNT=3", "ATTENDEE;PARTSTAT=ACCEPTED:mailto:me@gmail.com", "END:VEVENT",
        "BEGIN:VEVENT", "UID:c", "RECURRENCE-ID:20261012T010000Z", "SUMMARY:weekly, but declined once",
        "DTSTART:20261012T010000Z", "ATTENDEE;PARTSTAT=DECLINED:mailto:me@gmail.com", "END:VEVENT")

    static func calendar(_ lines: String...) -> Data { calendar(lines) }

    static func calendar(_ lines: [String]) -> Data {
        Data(("BEGIN:VCALENDAR\r\n" + lines.map { $0 + "\r\n" }.joined() + "END:VCALENDAR\r\n").utf8)
    }

    static func midnight(_ y: Int, _ m: Int, _ d: Int) -> Date { day(y, m, d).midnight(in: tpe) }

    /// October 2026 in UTC+8, as test_ical.py reads.
    private func parse(_ data: Data, owner: String = "") throws -> ParsedFeed {
        try ICal.parse(data, start: Self.midnight(2026, 10, 1), end: Self.midnight(2026, 11, 1), zone: tpe,
                       owner: owner)
    }

    private func event(_ lines: String...) -> Data {
        Self.calendar(["BEGIN:VEVENT", "UID:u", "SUMMARY:x"] + lines + ["END:VEVENT"])
    }

    private func series(_ start: String, _ rule: String) -> Data {
        Self.calendar("BEGIN:VEVENT", "UID:d", "SUMMARY:often", "DTSTART;TZID=Asia/Taipei:" + start,
                      "DURATION:PT10M", "RRULE:" + rule, "END:VEVENT")
    }

    private func starts(_ feed: ParsedFeed) -> [EventTime] {
        feed.events.map(\.start).sorted { $0.local(in: tpe) < $1.local(in: tpe) }
    }

    /// A date as it is, a time as an instant written in `zone`'s offset.
    static func text(_ time: EventTime, in zone: TimeZone) -> String {
        switch time {
        case .date(let d): d.iso
        case .dateTime(let t): t.converted(to: zone).iso
        }
    }
}

/// Python's order of (str, str) tuples.
private func codePointOrder(_ a: (String, String), _ b: (String, String)) -> Bool {
    let first = PaperhueAgenda.compareCodePoints(a.0, b.0)
    return first != 0 ? first < 0 : PaperhueAgenda.codePointsPrecede(a.1, b.1)
}

/// shared/vectors/ical-vectors.json.
struct ICalVectors: Decodable, Sendable {
    struct Case: Decodable, Sendable {
        let file: String
        let window: [String]
        let name: String
        let skipped: Int
        let events: [Event]
        let tasks: [Task]
    }

    struct Event: Decodable, Equatable, Sendable {
        let title: String, start: String, end: String
        let allDay: Bool
        let location: String
        enum CodingKeys: String, CodingKey { case title, start, end, allDay = "all_day", location }
    }

    struct Task: Decodable, Equatable, Sendable {
        let title: String
        let due: String?
        let notes: String
    }

    let utcOffset: String
    let cases: [Case]
    enum CodingKeys: String, CodingKey { case utcOffset = "utc_offset", cases }
}

/// Differential/parse-expectations.json.
struct ParseExpectations: Decodable, Sendable {
    struct Case: Decodable, Sendable {
        let file: String?
        let ics: String?
        let name: String?
        let color: String?
        let zoneName: String
        let window: [String]
        let result: Result

        enum CodingKeys: String, CodingKey { case file, ics, name, color, zoneName = "zone", window, result }

        /// ical.parse in `zone` over the window's local midnights.
        func parse(_ data: Data, name: String = "", color: String = "") throws -> Result {
            let tz = try zone(zoneName)
            do {
                let feed = try ICal.parse(data, start: try day(iso: window[0]).midnight(in: tz),
                                          end: try day(iso: window[1]).midnight(in: tz), zone: tz,
                                          name: name, color: color)
                return Result(feed)
            } catch is ICalError {
                return Result(error: "ICalError")
            }
        }
    }

    struct Result: Decodable, Equatable, Sendable, CustomStringConvertible {
        var name: String?
        var skipped: Int?
        /// [title, start, end, all day, calendar, location, colour]
        var events: [Row]?
        /// [title, due, list, notes]
        var tasks: [Row]?
        var error: String?

        init(error: String) { self.error = error }

        init(_ feed: ParsedFeed) {
            name = feed.name
            skipped = feed.skipped
            events = feed.events.map {
                Row([.text($0.title), .text(Self.iso($0.start)), .text(Self.iso($0.end)), .flag($0.allDay),
                     .text($0.calendar), .text($0.location), .text($0.color)])
            }
            tasks = feed.tasks.map {
                Row([.text($0.title), $0.due.map { .text($0.iso) } ?? .none, .text($0.listName), .text($0.notes)])
            }
        }

        static func iso(_ time: EventTime) -> String {
            switch time {
            case .date(let d): d.iso
            case .dateTime(let t): t.iso
            }
        }

        var description: String {
            if let error { return error }
            return "\(name ?? "") skipped \(skipped ?? 0)\n" + (events ?? []).map { "\($0)" }.joined(separator: "\n")
                + "\n" + (tasks ?? []).map { "\($0)" }.joined(separator: "\n")
        }
    }

    /// A JSON array of strings, booleans and nulls.
    struct Row: Decodable, Equatable, Sendable, CustomStringConvertible {
        enum Cell: Equatable, Sendable { case text(String), flag(Bool), none }

        let cells: [Cell]

        init(_ cells: [Cell]) { self.cells = cells }

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            var cells: [Cell] = []
            while !c.isAtEnd {
                if try c.decodeNil() {
                    cells.append(.none)
                } else if let flag = try? c.decode(Bool.self) {
                    cells.append(.flag(flag))
                } else {
                    cells.append(.text(try c.decode(String.self)))
                }
            }
            self.cells = cells
        }

        var description: String {
            cells.map { cell in
                switch cell {
                case .text(let text): text
                case .flag(let flag): "\(flag)"
                case .none: "null"
                }
            }.joined(separator: " | ")
        }
    }

    let files: [Case]
    let rules: [Case]

    private static let loaded = Swift.Result<ParseExpectations, any Error> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Differential/parse-expectations.json")
        return try JSONDecoder().decode(ParseExpectations.self, from: Data(contentsOf: url))
    }

    static func load() throws -> ParseExpectations { try loaded.get() }
}
