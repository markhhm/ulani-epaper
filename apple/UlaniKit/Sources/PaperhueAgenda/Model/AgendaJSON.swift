import Foundation

// AgendaData as JSON, for fixtures only (python/src/ulani_epaper/agenda.py `to_json` /
// `from_json`): calendar content is never written to disk.

/// JSON that cannot be read as agenda data or a page fixture. The message names the field,
/// never its content.
public struct FixtureError: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}

extension AgendaData {
    /// Python's `AgendaData.from_json`: "events", "tasks" and "fetched_at" with Python's field
    /// names. Dates are "YYYY-MM-DD"; a value with a "T" is a date-time and needs a UTC offset
    /// (Python would take a naive one as the computer's local time). Missing or null optional
    /// fields are "" / nil; `all_day` counts as Python's `bool()` of it. Other keys are ignored.
    /// Throws `FixtureError`.
    public static func fromJSON(_ json: Data) throws -> AgendaData {
        try fromJSONObject(try JSONFields.object(json))
    }

    /// Python's `AgendaData.to_json()`, byte for byte: instants in their own offsets.
    public func toJSON() -> String {
        typealias V = PythonJSON.Value
        func when(_ t: EventTime) -> V {
            switch t {
            case .date(let d): .string(d.iso)
            case .dateTime(let t): .string(t.iso)
            }
        }
        let events: [V] = events.map { e in
            .object([.init("title", .string(e.title)), .init("start", when(e.start)), .init("end", when(e.end)),
                     .init("all_day", .bool(e.allDay)), .init("calendar", .string(e.calendar)),
                     .init("location", .string(e.location)), .init("color", .string(e.color))])
        }
        let tasks: [V] = tasks.map { t in
            .object([.init("title", .string(t.title)), .init("due", t.due.map { .string($0.iso) } ?? .null),
                     .init("list_name", .string(t.listName)), .init("notes", .string(t.notes))])
        }
        return PythonJSON.dumps(.object([
            .init("events", .array(events)), .init("tasks", .array(tasks)),
            .init("fetched_at", fetchedAt.map { .string($0.iso) } ?? .null),
        ]))
    }

    static func fromJSONObject(_ raw: [String: Any]) throws -> AgendaData {
        var events: [Event] = []
        for (i, item) in try JSONFields.list(raw, "events").enumerated() {
            events.append(try event(JSONFields.member(item, "events[\(i)]"), at: "events[\(i)]"))
        }
        var tasks: [AgendaTask] = []
        for (i, item) in try JSONFields.list(raw, "tasks").enumerated() {
            tasks.append(try task(JSONFields.member(item, "tasks[\(i)]"), at: "tasks[\(i)]"))
        }
        var fetched: OffsetDateTime?
        if PythonJSON.truthy(raw["fetched_at"]) {
            let text = try JSONFields.string(raw, "fetched_at")
            guard let t = OffsetDateTime(iso: text) else {
                throw FixtureError("fetched_at: not a date-time with a UTC offset")
            }
            fetched = t
        }
        return AgendaData(events: events, tasks: tasks, fetchedAt: fetched)
    }

    private static func event(_ d: [String: Any], at path: String) throws -> Event {
        Event(title: try JSONFields.string(d, "title", at: path),
              start: try when(JSONFields.string(d, "start", at: path), at: "\(path).start"),
              end: try when(JSONFields.string(d, "end", at: path), at: "\(path).end"),
              allDay: PythonJSON.truthy(d["all_day"]),
              calendar: try JSONFields.optionalString(d, "calendar", at: path),
              location: try JSONFields.optionalString(d, "location", at: path),
              color: try JSONFields.optionalString(d, "color", at: path))
    }

    /// Python's `_when_from`: a "T" makes it a date-time.
    private static func when(_ text: String, at path: String) throws -> EventTime {
        if text.contains("T") {
            guard let t = OffsetDateTime(iso: text) else {
                throw FixtureError("\(path): not a date-time with a UTC offset")
            }
            return .dateTime(t)
        }
        guard let d = LocalDate(iso: text) else { throw FixtureError("\(path): not a date YYYY-MM-DD") }
        return .date(d)
    }

    private static func task(_ d: [String: Any], at path: String) throws -> AgendaTask {
        var due: LocalDate?
        if PythonJSON.truthy(d["due"]) {
            guard let text = PythonJSON.string(d["due"] as Any), let date = LocalDate(iso: text) else {
                throw FixtureError("\(path).due: not a date YYYY-MM-DD")
            }
            due = date
        }
        return AgendaTask(title: try JSONFields.string(d, "title", at: path), due: due,
                          listName: try JSONFields.optionalString(d, "list_name", at: path),
                          notes: try JSONFields.optionalString(d, "notes", at: path))
    }
}

/// Field access for the fixture readers, with errors that name the field only.
enum JSONFields {
    /// The top-level object of `json`.
    static func object(_ json: Data) throws -> [String: Any] {
        let parsed: Any
        do {
            parsed = try PythonJSON.parse(json)
        } catch {
            throw FixtureError("fixture: not valid JSON")
        }
        guard let object = parsed as? [String: Any] else { throw FixtureError("fixture: not a JSON object") }
        return object
    }

    /// An array member; missing or null is empty.
    static func list(_ d: [String: Any], _ key: String, at path: String = "") throws -> [Any] {
        switch d[key] {
        case nil, is NSNull: return []
        case let items as [Any]: return items
        default: throw FixtureError("\(name(path, key)): not a list")
        }
    }

    /// An array element that must be an object.
    static func member(_ item: Any, _ path: String) throws -> [String: Any] {
        guard let object = item as? [String: Any] else { throw FixtureError("\(path): not an object") }
        return object
    }

    /// A required string.
    static func string(_ d: [String: Any], _ key: String, at path: String = "") throws -> String {
        guard let value = d[key], !(value is NSNull) else { throw FixtureError("\(name(path, key)): missing") }
        guard let s = PythonJSON.string(value) else { throw FixtureError("\(name(path, key)): not a string") }
        return s
    }

    /// An optional string: missing or null is "".
    static func optionalString(_ d: [String: Any], _ key: String, at path: String = "",
                               default fallback: String = "") throws -> String {
        guard let value = d[key], !(value is NSNull) else { return fallback }
        guard let s = PythonJSON.string(value) else { throw FixtureError("\(name(path, key)): not a string") }
        return s
    }

    /// "events[3].title".
    static func name(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
}
