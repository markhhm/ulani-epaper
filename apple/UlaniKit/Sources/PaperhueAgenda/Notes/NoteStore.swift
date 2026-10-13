import Foundation

/// The notes file, newest first, written atomically (python/src/ulani_epaper/notes.py):
///
///     {"version": 1, "notes": [{"id": "a1b2c3d4", "text": "...",
///                               "at": "2026-10-12T14:03:00+08:00", "color": "yellow"}]}
///
/// The file is the app's to choose (`url`); it is written exactly as the Python reference
/// writes it. A file that cannot be read or is invalid is reported and never overwritten.
/// Every method throws `NoteError`.
public struct NoteStore: Sendable {
    public static let version = 1
    /// Adding one more drops the oldest.
    public static let maxNotes = 50

    public let url: URL
    private let token: @Sendable () -> String

    /// `token` draws an id candidate, 8 lower-case hex characters (Python:
    /// `secrets.token_hex(4)`); tests inject their own.
    public init(url: URL, token: @escaping @Sendable () -> String = NoteStore.randomToken) {
        self.url = url
        self.token = token
    }

    /// 4 random bytes as 8 lower-case hex characters, from the system's secure generator.
    public static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = generator.next() as UInt32
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// The notes, newest first. A missing file means no notes.
    public func load() throws -> [Note] {
        guard let raw = try read() else { return [] }
        do {
            return try Self.notes(from: raw)
        } catch let error as NoteError {
            throw NoteError.invalidFile(path: url.path, reason: error.description)
        }
    }

    /// Writes `notes` (newest first) atomically, creating the folder if needed: a temporary
    /// file next to it, readable by this user only (Python's mkstemp), renamed over it.
    public func save(_ notes: [Note]) throws {
        try Self.validate(notes)
        let items: [PythonJSON.Value] = notes.map { n in
            .object([.init("id", .string(n.id)), .init("text", .string(n.text)), .init("at", .string(n.at)),
                     .init("color", .string(n.color))])
        }
        let text = PythonJSON.dumps(.object([.init("version", .int(Self.version)), .init("notes", .array(items))]))
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw NoteError.cannotSave(path: url.path, reason: error.localizedDescription)
        }
        let temporary = folder.appendingPathComponent(".notes-\(Self.randomToken()).tmp").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw NoteError.cannotSave(path: url.path, reason: String(cString: strerror(errno))) }
        var failure: String?
        do {
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: Data(text.utf8))
        } catch {
            failure = error.localizedDescription
        }
        if close(fd) != 0, failure == nil { failure = String(cString: strerror(errno)) }
        if failure == nil, rename(temporary, url.path) != 0 { failure = String(cString: strerror(errno)) }
        if let failure {
            unlink(temporary)
            throw NoteError.cannotSave(path: url.path, reason: failure)
        }
    }

    /// Saves a new note on top; beyond `maxNotes` the oldest is dropped. `now` (the current
    /// time in this Mac's zone if nil) is kept to the second, in its own offset.
    @discardableResult
    public func add(_ text: String, color: String = Note.defaultColour,
                    now: OffsetDateTime? = nil) throws -> Note {
        let text = try Note.checkText(text)
        try Note.checkColour(color)
        let notes = try load()
        let now = now ?? OffsetDateTime(Date(), in: .current)
        let wall = now.wallClock
        let at = OffsetDateTime(wall.adding(microseconds: -wall.microsecond), utcOffset: now.utcOffset).iso
        let taken = Set(notes.map(\.id))
        var id = token()
        while taken.contains(id) { id = token() }
        let note = Note(id: id, text: text, at: at, color: color)
        try save([note] + notes.prefix(Self.maxNotes - 1))
        return note
    }

    /// Deletes one note by id (any case, outer spaces ignored) or by its 1-based position
    /// (newest = 1); an id made of digits wins over a position. Returns it.
    @discardableResult
    public func remove(_ key: String) throws -> Note {
        var notes = try load()
        let note = notes.remove(at: try Self.find(notes, key))
        try save(notes)
        return note
    }

    /// `remove` by 1-based position (newest = 1).
    @discardableResult
    public func remove(_ position: Int) throws -> Note {
        try remove(String(position))
    }

    /// Deletes every note; returns how many there were. No notes: the file is not touched.
    @discardableResult
    public func clear() throws -> Int {
        let notes = try load()
        if !notes.isEmpty { try save([]) }
        return notes.count
    }

    // MARK: -

    /// The parsed JSON; nil for a missing file.
    private func read() throws -> Any? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw NoteError.unreadableFile(path: url.path, reason: error.localizedDescription)
        }
        // Python reads the file as strict UTF-8 and json.loads refuses a byte order mark.
        guard String(data: data, encoding: .utf8) != nil, !data.starts(with: [0xEF, 0xBB, 0xBF]) else {
            throw NoteError.unreadableFile(path: url.path, reason: "not UTF-8 JSON")
        }
        do {
            return try PythonJSON.parse(data)
        } catch {
            throw NoteError.unreadableFile(path: url.path, reason: "not valid JSON")
        }
    }

    /// The notes in a parsed notes file, validated (Python: the body of `load`).
    static func notes(from raw: Any) throws -> [Note] {
        guard let object = raw as? [String: Any] else { throw NoteError.invalidNotes("not a JSON object") }
        guard let version = object["version"] as? NSNumber, version.doubleValue == Double(Self.version) else {
            throw NoteError.invalidNotes("unknown version \(object["version"].map { "\($0)" } ?? "None")")
        }
        guard let items = object["notes"] as? [Any] else { throw NoteError.invalidNotes("no list of notes") }
        var notes: [Note] = []
        for (i, item) in items.enumerated() {
            guard let n = item as? [String: Any] else { throw NoteError.invalidNotes("note \(i + 1) is not an object") }
            guard let id = n["id"], let text = n["text"], let at = n["at"] else {
                throw NoteError.invalidNotes("note \(i + 1) lacks an id, a text or a time")
            }
            let color = n["color"] ?? Note.defaultColour  // Python: n.get("color", "yellow")
            let strings = [id, text, at, color].compactMap(PythonJSON.string)
            guard strings.count == 4 else { throw NoteError.invalidNotes("note \(i + 1): fields must be strings") }
            notes.append(Note(id: strings[0], text: strings[1], at: strings[2], color: strings[3]))
        }
        try validate(notes)
        return notes
    }

    /// Python: `_validate`. The text and colour rules throw their own errors, the rest
    /// `invalidNotes` (English, like Python's ValueError).
    static func validate(_ notes: [Note]) throws {
        if notes.count > maxNotes { throw NoteError.invalidNotes("at most \(maxNotes) notes, got \(notes.count)") }
        var seen = Set<String>()
        for n in notes {
            guard isNoteID(n.id), !seen.contains(n.id) else {
                throw NoteError.invalidNotes("note ids must be 8 hex characters and unique, got \(pythonRepr(n.id))")
            }
            seen.insert(n.id)
            if try Note.checkText(n.text) != n.text {
                throw NoteError.invalidNotes("note \(n.id): text is not normalized")
            }
            guard let parsed = ISODateTime.parse(n.at) else {
                throw NoteError.invalidNotes("note \(n.id): invalid time \(pythonRepr(n.at))")
            }
            if parsed.utcOffset == nil {
                throw NoteError.invalidNotes("note \(n.id): time \(pythonRepr(n.at)) has no UTC offset")
            }
            try Note.checkColour(n.color)
        }
    }

    /// 8 characters of 0-9 a-f.
    static func isNoteID(_ id: String) -> Bool {
        let b = Array(id.utf8)
        return b.count == 8 && b.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Python: `_find`.
    static func find(_ notes: [Note], _ key: String) throws -> Int {
        let k = Note.strip(key.unicodeScalars).lowercased()
        if let i = notes.firstIndex(where: { $0.id == k }) { return i }
        if !k.isEmpty, k.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let n = Int(k), n >= 1, n <= notes.count {
            return n - 1
        }
        throw notes.isEmpty ? NoteError.noNotes : NoteError.noSuchNote(key: key, count: notes.count)
    }
}
