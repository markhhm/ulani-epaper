import Foundation

// The calendar page fixtures in shared/layouts/agenda/ that the golden renders are drawn from,
// read as python/src/ulani_epaper/layouts.py (`_golden_pages`) and python/tests/test_layouts.py
// read them.
// `init(json:)` throws `FixtureError`; `init(contentsOf:)` also the file's read error.

/// A calendar page fixture (shared/layouts/agenda/*.json): `AgendaData` JSON plus "today"
/// (the page's date) and "utc_offset" (its zone, "+08:00").
public struct AgendaFixture: Sendable {
    public var data: AgendaData
    public var today: LocalDate
    /// As written in the file.
    public var utcOffset: String
    /// The fixed zone of `utcOffset`.
    public var zone: TimeZone

    public init(json: Data) throws {
        try self.init(object: JSONFields.object(json))
    }

    public init(contentsOf url: URL) throws {
        try self.init(json: Data(contentsOf: url))
    }

    init(object raw: [String: Any]) throws {
        guard let today = LocalDate(iso: try JSONFields.string(raw, "today")) else {
            throw FixtureError("today: not a date YYYY-MM-DD")
        }
        let (offset, zone) = try fixtureZone(raw)
        self.utcOffset = offset
        self.zone = zone
        self.today = today
        data = try AgendaData.fromJSONObject(raw)
    }
}

/// "utc_offset" and its fixed zone. Python: `strptime(text.replace(":", ""), "%z")`, so "Z",
/// "+HHMM", "+HH:MM" and the same with seconds.
func fixtureZone(_ raw: [String: Any]) throws -> (String, TimeZone) {
    let text = try JSONFields.string(raw, "utc_offset")
    let compact = Array(text.utf8.filter { $0 != UInt8(ascii: ":") })
    guard compact == [UInt8(ascii: "Z")] || compact.count == 5 || compact.count == 7,
          let seconds = ISODateTime.offsetSeconds(compact[...]),
          let zone = TimeZone(secondsFromGMT: seconds) else {
        throw FixtureError("utc_offset: not a UTC offset such as +08:00")
    }
    return (text, zone)
}
