import Foundation
import Testing
@testable import PaperhueAgenda

// Repo test data read straight from the checkout (one source of truth), and the
// expectations computed with the Python reference (Differential/make_agenda_expectations.py).

enum Repo {
    /// The repository root: this file's directory, up 4 directories.
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/PaperhueAgendaTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // UlaniKit
        .deletingLastPathComponent()  // apple
        .deletingLastPathComponent()  // repo root

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    /// shared/layouts/agenda/<name>.json
    static func agendaFixture(_ name: String) -> URL { url("shared/layouts/agenda/\(name).json") }

    static let agendaFixtureNames = ["sample", "empty", "busy", "midday"]
}

/// Differential/agenda-expectations.json.
struct Expectations: Decodable, Sendable {
    struct Fixture: Decodable, Sendable {
        let eventsOn: [String: [String: [Int]]]  // zone -> ISO day -> event indices
        let sortedTasks: [Int]
        let toJSON: String
        enum CodingKeys: String, CodingKey { case eventsOn = "events_on", sortedTasks = "sorted_tasks", toJSON = "to_json" }
    }

    struct Case: Decodable, Sendable {
        let name: String
        let zone: String
        let data: String  // AgendaData JSON (Python from_json input)
        let eventsOn: [String: [Int]]
        let sortedTasks: [Int]
        enum CodingKeys: String, CodingKey {
            case name, zone, data, eventsOn = "events_on", sortedTasks = "sorted_tasks"
        }
    }

    struct ToJSON: Decodable, Sendable {
        let input: String
        let output: String
        let empty: String
    }

    /// A wall time read in a zone: zoneinfo's fold=0 instant and agenda.LOCAL's (microseconds).
    struct Wall: Decodable, Sendable {
        let zone: String
        let wall: String
        let fold0: Int
        let offset: Int
        let local: Int
    }

    /// An instant and its wall time and offset in a zone (astimezone); what agenda.LOCAL's
    /// utcoffset() says for that wall time.
    struct Instant: Decodable, Sendable {
        let zone: String
        let instant: String
        let micros: Int
        let wall: String
        let offset: Int
        let localOffset: Int
        enum CodingKeys: String, CodingKey { case zone, instant, micros, wall, offset, localOffset = "local_offset" }
    }

    struct DateCase: Decodable, Sendable {
        let iso: String
        let ordinal: Int
        let weekday: Int
    }

    struct Month: Decodable, Sendable {
        let year: Int
        let month: Int
        let firstWeekday: Int
        let first: String
        let weeks: Int
        enum CodingKeys: String, CodingKey { case year, month, firstWeekday = "first_weekday", first, weeks }
    }

    /// datetime.fromisoformat (with "ok") or date.fromisoformat (with "date") of `text`.
    struct ISOCase: Decodable, Sendable {
        let text: String
        let swiftRefuses: Bool
        let ok: Bool?
        let wall: String?
        let offset: Int?
        let micros: Int?
        let isoformat: String?
        let date: String?
        let isDateCase: Bool
        enum CodingKeys: String, CodingKey {
            case text, swiftRefuses = "swift_refuses", ok, wall, offset, micros, isoformat, date
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            swiftRefuses = try c.decode(Bool.self, forKey: .swiftRefuses)
            ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
            wall = try c.decodeIfPresent(String.self, forKey: .wall)
            offset = try c.decodeIfPresent(Int.self, forKey: .offset)
            micros = try c.decodeIfPresent(Int.self, forKey: .micros)
            isoformat = try c.decodeIfPresent(String.self, forKey: .isoformat)
            date = try c.decodeIfPresent(String.self, forKey: .date)
            isDateCase = c.contains(.date)
        }
    }

    let fixtures: [String: Fixture]
    let cases: [Case]
    let toJSON: ToJSON
    let walls: [Wall]
    let instants: [Instant]
    let dates: [DateCase]
    let months: [Month]
    let iso: [ISOCase]

    enum CodingKeys: String, CodingKey {
        case fixtures, cases, toJSON = "to_json", walls, instants, dates, months, iso
    }

    private static let loaded = Result<Expectations, any Error> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Differential/agenda-expectations.json")
        return try JSONDecoder().decode(Expectations.self, from: Data(contentsOf: url))
    }

    static func load() throws -> Expectations { try loaded.get() }
}

/// "+08:00" / "-03:30" -> a fixed offset; anything else is an IANA name.
func zone(_ name: String) throws -> TimeZone {
    if let sign = name.first, sign == "+" || sign == "-" {
        let n = name.dropFirst().split(separator: ":").compactMap { Int($0) }
        try #require(n.count == 2, "zone \(name)")
        let seconds = (n[0] * 3600 + n[1] * 60) * (sign == "-" ? -1 : 1)
        return try #require(TimeZone(secondsFromGMT: seconds), "zone \(name)")
    }
    return try #require(TimeZone(identifier: name), "zone \(name)")
}

/// A valid date (test shorthand).
func day(_ year: Int, _ month: Int, _ day: Int) -> LocalDate {
    guard let d = LocalDate(year: year, month: month, day: day) else {
        preconditionFailure("invalid test date \(year)-\(month)-\(day)")
    }
    return d
}

/// A valid wall time (test shorthand).
func wall(_ year: Int, _ month: Int, _ d: Int, _ hour: Int, _ minute: Int, _ second: Int = 0,
          microsecond: Int = 0) -> LocalDateTime {
    guard let w = LocalDateTime(date: day(year, month, d), hour: hour, minute: minute, second: second,
                                microsecond: microsecond) else {
        preconditionFailure("invalid test time")
    }
    return w
}

/// "YYYY-MM-DDTHH:MM:SS[.ffffff]" -> wall time, parsed here (independent of the code under test).
func wall(iso text: String) throws -> LocalDateTime {
    let parts = text.split(separator: ".")
    let n = parts[0].split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
    try #require(n.count == 6, "wall \(text)")
    let micro = parts.count > 1 ? try #require(Int(parts[1]), "wall \(text)") : 0
    return wall(n[0], n[1], n[2], n[3], n[4], n[5], microsecond: micro)
}

/// "YYYY-MM-DD" -> date, parsed here (independent of the code under test).
func day(iso text: String) throws -> LocalDate {
    let n = text.split(separator: "-").compactMap { Int($0) }
    try #require(n.count == 3, "day \(text)")
    return day(n[0], n[1], n[2])
}

/// Microseconds since 1970 -> Date.
func instant(micros: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(micros / 1_000_000) + TimeInterval(micros % 1_000_000) / 1e6)
}

/// A timed value at a wall time in `zone` (Taipei by default).
func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int, _ zone: TimeZone = tpe) -> EventTime {
    .dateTime(OffsetDateTime(wall(y, m, d, h, mi).instant(in: zone), in: zone))
}

/// Taipei, as the Python tests use it: a fixed UTC+8.
let tpe = TimeZone(secondsFromGMT: 8 * 3600)!
let utc = TimeZone(secondsFromGMT: 0)!
