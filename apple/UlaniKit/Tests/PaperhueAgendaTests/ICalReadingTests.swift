import Foundation
import Testing
@testable import PaperhueAgenda

/// Reading iCalendar data as the Python reference does (icalendar under
/// python/src/ulani_epaper/ical.py): every case of Differential/ical-expectations.json
/// (Differential/make_ical_expectations.py), and the reading cases of python/tests/test_ical.py.
@Suite struct ICalReadingTests {
    @Test func calendarsReadAsInPython() throws {
        let cases = try ICalExpectations.load().reading
        #expect(cases.count == 26)
        for c in cases {
            let data = try c.file.map { try Data(contentsOf: Repo.url($0)) } ?? Data((c.ics ?? "").utf8)
            let got = (try? ICalendar.read(data)).map(ICalExpectations.describe)
            #expect(got == c.components, "\(c.name)")
        }
    }

    @Test func zonesMatchPython() throws {
        let zones = try ICalExpectations.load().zones
        #expect(zones.count == 8)
        for z in zones {
            let zone = try #require(try ICalExpectations.zone(z.zone, vtimezone: z.vtimezone), "\(z.zone)")
            for check in z.offsets {
                #expect(zone.utcOffset(try wall(iso: check.key)) == check.value, "\(z.zone) \(check.key)")
            }
            for check in z.wallClock {
                let instant = try wall(iso: check.key).instant(in: utc)
                #expect(zone.wallClock(at: instant).iso == check.value, "\(z.zone) \(check.key)Z")
            }
        }
    }

    /// Python subtracts and compares aware datetimes that share a tzinfo on the wall clock, others
    /// as instants.
    @Test func differencesMatchPython() throws {
        let expectations = try ICalExpectations.load()
        for d in expectations.differences {
            let zoneA = try #require(try ICalExpectations.zone(d.zoneA, vtimezone: expectations.vtimezone(d.zoneA)))
            let zoneB = d.zoneA == d.zoneB
                ? zoneA : try #require(try ICalExpectations.zone(d.zoneB, vtimezone: expectations.vtimezone(d.zoneB)))
            let a = ICalDateTime(wall: try wall(iso: d.wallA), zone: zoneA)
            let b = ICalDateTime(wall: try wall(iso: d.wallB), zone: zoneB)
            #expect(b.seconds(since: a) == d.seconds, "\(d.zoneA) \(d.wallA) -> \(d.zoneB) \(d.wallB)")
        }
    }

    @Test func wallClockArithmetic() throws {
        let newYork = try #require(ICalZone.zoneinfo("America/New_York"))
        let before = ICalDateTime(wall: wall(2026, 3, 8, 1, 30), zone: newYork)
        let later = before.adding(seconds: 3600)  // 02:30 does not exist that day: fold=0 keeps -05:00
        #expect(later.wall == wall(2026, 3, 8, 2, 30) && later.zone == newYork && later.utcOffset == -5 * 3600)
        #expect(later.description == "2026-03-08T02:30:00-05:00")
        let floating = ICalDateTime(wall: wall(2026, 3, 8, 3, 0), zone: nil)
        #expect(floating.seconds(since: before) == nil)  // Python: TypeError
        #expect(floating.utcOffset == nil && floating.instant == nil && floating.description == "2026-03-08T03:00:00")
        #expect(ICalDateTime(try #require(before.instant), in: .utc).wall == wall(2026, 3, 8, 6, 30))
    }

    @Test func everyKnownZoneNameLoads() {
        #expect(ZoneTables.ianaNames.count == 598)
        #expect(ZoneTables.ianaNames.allSatisfy { ICalZone.zoneinfo($0) != nil })
        #expect(ZoneTables.windowsToIANA.values.allSatisfy { ICalZone.zoneinfo($0) != nil })
        #expect(ICalZone.zoneinfo("GMT+8") == nil && ICalZone.zoneinfo("asia/taipei") == nil)
    }

    @Test(arguments: ["", "<html>not a calendar</html>", "BEGIN:VCARD\r\nEND:VCARD\r\n"])
    func notACalendar(text: String) {
        #expect(throws: ICalError.self) { try ICalendar.read(Data(text.utf8)) }
    }

    /// test_ical.py::test_custom_time_zones_do_not_leak_between_feeds, at the reading level.
    @Test func customZonesBelongToOneFile() throws {
        func offset(_ utcOffset: String) throws -> Int? {
            let text = calendar("BEGIN:VTIMEZONE", "TZID:Customized Time Zone", "BEGIN:STANDARD",
                                "DTSTART:19700101T000000", "TZOFFSETFROM:\(utcOffset)", "TZOFFSETTO:\(utcOffset)",
                                "END:STANDARD", "END:VTIMEZONE", "BEGIN:VEVENT",
                                "DTSTART;TZID=Customized Time Zone:20261012T090000", "END:VEVENT")
            guard case .dateTime(let start)? = try ICalendar.read(text).walk("VEVENT")[0].first("DTSTART")?.value
            else { return nil }
            return start.utcOffset
        }
        #expect(try offset("-0500") == -5 * 3600)
        #expect(try offset("+0100") == 3600)
    }

    @Test func repeatedPropertiesKeepTheirOrder() throws {
        let event = try ICalendar.read(calendar("BEGIN:VEVENT", "SUMMARY:一", "summary:二", "END:VEVENT"))
            .walk("VEVENT")[0]
        #expect(event.first("SUMMARY")?.text == "一")
        #expect(event.all("summary").map(\.text) == ["一", "二"])
        #expect(event.contains("Summary") && !event.contains("LOCATION"))
    }

    @Test func parametersAndText() throws {
        let event = try ICalendar.read(calendar(
            "BEGIN:VEVENT", #"ATTENDEE;CN="Doe, John";MEMBER="a","b";partstat=DECLINED:mailto:me@x.org"#,
            #"SUMMARY:a\, b\nc"#, #"X-NAME:a\, b"#, "END:VEVENT")).walk("VEVENT")[0]
        let attendee = try #require(event.first("ATTENDEE"))
        #expect(attendee.parameter("partstat") == "DECLINED" && attendee.parameter("CN") == "Doe, John")
        #expect(attendee.parameters["MEMBER"] == ["a", "b"] && attendee.text == "mailto:me@x.org")
        #expect(event.first("SUMMARY")?.text == "a, b\nc" && event.first("SUMMARY")?.raw == #"a\, b\nc"#)
        #expect(event.first("X-NAME")?.text == #"a\, b"#)  // icalendar keeps unknown properties verbatim
    }

    /// The owner's rule: what a calendar holds never reaches an error.
    @Test func errorsNeverQuoteTheData() {
        let secret = "Secret meeting at 5 Main St"
        for text in [calendar("BEGIN:VTODO", "DUE:\(secret)", "END:VTODO"), calendar(secret),
                     calendar("BEGIN:VTIMEZONE", "TZID:\(secret)", "END:VTIMEZONE")] {
            do {
                _ = try ICalendar.read(text)
                Issue.record("read")
            } catch {
                #expect(!"\(error)".contains("Secret") && !"\(error)".contains("Main"))
            }
        }
    }

    private func calendar(_ lines: String...) -> Data {
        Data(("BEGIN:VCALENDAR\r\n" + lines.map { $0 + "\r\n" }.joined() + "END:VCALENDAR\r\n").utf8)
    }
}

/// Differential/ical-expectations.json, and the Swift reader's results written the same way.
enum ICalExpectations {
    struct File: Decodable, Sendable {
        let reading: [Reading]
        let zones: [Zone]
        let differences: [Difference]

        func vtimezone(_ name: String) -> String { zones.first { $0.zone == name }?.vtimezone ?? "" }
    }

    struct Reading: Decodable, Sendable {
        let name: String
        let ics: String?
        let file: String?
        /// nil: not a calendar.
        let components: [Described]?
    }

    /// A component's name and its properties, as `[name, [line]]`.
    struct Described: Decodable, Equatable, Sendable, CustomStringConvertible {
        let name: String
        let lines: [String]

        init(name: String, lines: [String]) {
            self.name = name
            self.lines = lines
        }

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            name = try c.decode(String.self)
            lines = try c.decode([String].self)
        }

        var description: String { "\(name) \(lines)" }
    }

    struct Zone: Decodable, Sendable {
        let zone: String
        let vtimezone: String
        let offsets: [Pair<Int>]
        let wallClock: [Pair<String>]

        enum CodingKeys: String, CodingKey {
            case zone, vtimezone, offsets
            case wallClock = "wall_clock"
        }
    }

    struct Pair<Value: Decodable & Sendable>: Decodable, Sendable {
        let key: String
        let value: Value

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            key = try c.decode(String.self)
            value = try c.decode(Value.self)
        }
    }

    struct Difference: Decodable, Sendable {
        let zoneA: String, wallA: String, zoneB: String, wallB: String
        let seconds: Int

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            (zoneA, wallA) = (try c.decode(String.self), try c.decode(String.self))
            (zoneB, wallB) = (try c.decode(String.self), try c.decode(String.self))
            seconds = try c.decode(Int.self)
        }
    }

    private static let loaded = Result<File, any Error> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Differential/ical-expectations.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    static func load() throws -> File { try loaded.get() }

    /// An IANA zone, or the zone a feed's VTIMEZONE text defines (read through a calendar).
    static func zone(_ name: String, vtimezone: String) throws -> ICalZone? {
        if vtimezone.isEmpty { return ICalZone.zoneinfo(name) }
        let text = "BEGIN:VCALENDAR\r\n\(vtimezone)\r\nBEGIN:VEVENT\r\nDTSTART;TZID=\(name):20261012T090000\r\n"
            + "END:VEVENT\r\nEND:VCALENDAR\r\n"
        guard case .dateTime(let start)? = try ICalendar.read(Data(text.utf8)).walk("VEVENT")[0].first("DTSTART")?.value
        else { return nil }
        return start.zone
    }

    private static let text: Set = ["SUMMARY", "LOCATION", "DESCRIPTION", "UID", "STATUS", "ATTENDEE",
                                    "PERCENT-COMPLETE", "TZID", "X-WR-CALNAME", "X-WR-TIMEZONE"]
    private static let dates: Set = ["DTSTART", "DTEND", "DUE", "RECURRENCE-ID", "DURATION", "RDATE", "EXDATE"]

    static func describe(_ calendar: ICalComponent) -> [Described] {
        calendar.walk().map { component in
            let names = Set(component.properties.map(\.name)).filter { text.contains($0) || dates.contains($0) }
            return Described(name: component.name, lines: names.sorted().flatMap { component.all($0).map(show) })
        }
    }

    private static func show(_ p: ICalProperty) -> String {
        let parameters = p.parameters.keys.sorted().map { "\($0)=\(p.parameters[$0]!.joined(separator: ","))" }
        let head = ([p.name] + parameters).joined(separator: ";")
        if p.isBroken { return head + " broken" }
        if dates.contains(p.name) { return head + " " + p.values.map(when).joined(separator: ", ") }
        return head + ":" + p.text
    }

    private static func when(_ value: ICalValue) -> String {
        switch value {
        case .date(let d): return "date " + d.iso
        case .duration(let seconds): return "duration \(seconds)"
        case .period: return "period"
        case .dateTime(let t):
            guard let instant = t.instant else { return "floating " + t.wall.iso }
            return "\(t) (\(ICalZone.utc.wallClock(at: instant).iso)Z)"
        }
    }
}
