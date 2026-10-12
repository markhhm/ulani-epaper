import Foundation

// The message board fixtures in shared/layouts/board/, read as python/tests/test_board_layouts.py
// and layouts.py (`_golden_pages`) read them. `init(json:)` throws `FixtureError`;
// `init(contentsOf:)` also the file's read error.

/// A message board fixture (shared/layouts/board/*.json): "notes" (as in notes.json, newest
/// first, not validated: Python builds the `Note`s directly) plus "utc_offset".
public struct BoardFixture: Sendable {
    public var notes: [Note]
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
        let (offset, zone) = try fixtureZone(raw)
        self.utcOffset = offset
        self.zone = zone
        guard let items = raw["notes"] as? [Any] else { throw FixtureError("notes: not a list") }
        var notes: [Note] = []
        for (i, item) in items.enumerated() {
            let path = "notes[\(i)]"
            let n = try JSONFields.member(item, path)
            notes.append(Note(id: try JSONFields.string(n, "id", at: path),
                              text: try JSONFields.string(n, "text", at: path),
                              at: try JSONFields.string(n, "at", at: path),
                              color: try JSONFields.optionalString(n, "color", at: path, default: Note.defaultColour)))
        }
        self.notes = notes
    }
}

/// Either kind of page fixture: a file with "notes" is a board fixture (layouts._golden_pages).
public enum LayoutFixture: Sendable {
    case agenda(AgendaFixture)
    case board(BoardFixture)

    public init(json: Data) throws {
        let raw = try JSONFields.object(json)
        self = raw["notes"] != nil ? .board(try BoardFixture(object: raw)) : .agenda(try AgendaFixture(object: raw))
    }

    public init(contentsOf url: URL) throws {
        try self.init(json: Data(contentsOf: url))
    }
}
