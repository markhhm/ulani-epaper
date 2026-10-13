import Foundation
import Testing
@testable import PaperhueAgenda

/// A folder for one test's notes files.
private struct Folder: Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("paperhue-notes-\(UUID().uuidString)")

    func file(_ name: String = "notes.json") -> URL { url.appendingPathComponent(name) }
}

/// Hands out the given id candidates, then random ones (Python tests patch secrets.token_hex).
private final class Tokens: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String]

    init(_ queue: [String]) { self.queue = queue }

    func next() -> String {
        lock.withLock { queue.isEmpty ? NoteStore.randomToken() : queue.removeFirst() }
    }
}

private let now = OffsetDateTime(wall(2026, 10, 12, 14, 3, 27, microsecond: 123_456), utcOffset: 8 * 3600)

private func later(minutes: Int) -> OffsetDateTime {
    OffsetDateTime(now.wallClock.adding(seconds: minutes * 60), utcOffset: now.utcOffset)
}

private func text(of url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

/// The NoteError `body` throws, or nil.
private func noteError(_ body: () throws -> Void) -> NoteError? {
    do {
        try body()
        return nil
    } catch {
        return error as? NoteError
    }
}

/// Three notes "a", "b", "c" written a minute apart; newest first.
private func three(_ store: NoteStore) throws -> [Note] {
    try ["a", "b", "c"].enumerated().map { i, t in try store.add(t, now: later(minutes: i)) }.reversed()
}

/// python/tests/test_notes.py (the store sits on a file the app chooses, so the
/// config-folder cases become "the file it is given"). Each test gets its own instance and
/// with it a fresh folder, removed afterwards.
@Suite final class NoteTests: Sendable {
    private let folder = Folder()

    deinit { try? FileManager.default.removeItem(at: folder.url) }

    @Test func noFileMeansNoNotes() throws {
        #expect(try NoteStore(url: folder.file()).load() == [])
    }

    @Test func addSavesNewestFirstAndRoundTrips() throws {
        let url = folder.url.appendingPathComponent("sub/notes.json")
        let store = NoteStore(url: url)
        let first = try store.add("晚餐在冰箱", now: now)
        let second = try store.add("  我去接小孩\r\n六點前回來  ", color: "red",
                                   now: OffsetDateTime(now.wallClock.adding(seconds: 7200), utcOffset: 8 * 3600))
        #expect(try store.load() == [second, first])
        #expect(second.text == "我去接小孩\n六點前回來" && second.color == "red")
        #expect(first == Note(id: first.id, text: "晚餐在冰箱", at: "2026-10-12T14:03:27+08:00", color: "yellow"))
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
        #expect(raw == [
            "version": 1,
            "notes": [
                ["id": second.id, "text": "我去接小孩\n六點前回來", "at": "2026-10-12T16:03:27+08:00", "color": "red"],
                ["id": first.id, "text": "晚餐在冰箱", "at": "2026-10-12T14:03:27+08:00", "color": "yellow"],
            ],
        ] as NSDictionary)
        #expect(try text(of: url).contains("晚餐"))  // readable UTF-8, not \u escapes
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                == ["notes.json"])  // no temporary files left
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)  // as Python's mkstemp leaves it
    }

    @Test func aFileThatCannotBeWrittenIsReported() throws {
        let url = folder.file()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)  // a folder in its place
        let error = noteError { try NoteStore(url: url).save([]) }
        guard case .cannotSave(let path, _) = error else { Issue.record("\(String(describing: error))"); return }
        #expect(path == url.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["notes.json"])
    }

    @Test func theDefaultTime() throws {
        let note = try NoteStore(url: folder.file()).add("hi")
        let written = try #require(note.written)
        #expect(abs(written.instant.timeIntervalSinceNow) < 86_400)
        #expect(written.utcOffset == TimeZone.current.secondsFromGMT(for: written.instant))
        #expect(written.wallClock.microsecond == 0)
        #expect(try NoteStore(url: folder.file()).load() == [note])
    }

    @Test func idsAreEightHexCharactersAndUnique() throws {
        let tokens = Tokens(["aaaaaaaa", "aaaaaaaa", "bbbbbbbb"])
        let store = NoteStore(url: folder.file(), token: { tokens.next() })
        #expect(try store.add("a").id == "aaaaaaaa")
        #expect(try store.add("b").id == "bbbbbbbb")  // the repeat was drawn again
        let ids = try (0..<20).map { try NoteStore(url: folder.file()).add(String($0)).id }
        #expect(ids.allSatisfy(NoteStore.isNoteID) && Set(ids).count == 20)
        #expect((0..<200).allSatisfy { _ in NoteStore.isNoteID(NoteStore.randomToken()) })
    }

    @Test func addingBeyondTheLimitDropsTheOldest() throws {
        let store = NoteStore(url: folder.file())
        for i in 0..<(NoteStore.maxNotes + 2) {
            try store.add("留言 \(i)", now: later(minutes: i))
        }
        let kept = try store.load()
        #expect(kept.count == NoteStore.maxNotes && NoteStore.maxNotes == 50)
        #expect(kept.first?.text == "留言 51" && kept.last?.text == "留言 2")
    }

    @Test(arguments: [
        ("", "留言是空的"),
        (" \n\t ", "留言是空的"),
        (String(repeating: "字", count: 301), "最多 300 字"),
        ("一二三四五六七八九".map(String.init).joined(separator: "\n"), "最多 8 行"),
    ])
    func unacceptableTextIsRefused(text: String, message: String) throws {
        let error = noteError { _ = try NoteStore(url: folder.file()).add(text) }
        #expect(error?.description.contains(message) == true, "\(String(describing: error))")
        #expect(!FileManager.default.fileExists(atPath: folder.file().path))
    }

    @Test func limitsCountAfterComposingAndStripping() throws {
        let store = NoteStore(url: folder.file("n.json"))
        let decomposed = String(repeating: "e\u{301}", count: 300)  // 600 code points, 300 once composed
        let note = try store.add("  " + decomposed + "  ")
        #expect(note.text == String(repeating: "\u{E9}", count: 300) && note.text.unicodeScalars.count == 300)
        let eight = "一二三四五六七八".map(String.init).joined(separator: "\n")
        #expect(try store.add(eight).text.filter { $0 == "\n" }.count == 7)
        #expect(Note.normalize(" a\r\nb ").unicodeScalars.count == 3)
    }

    @Test func unknownColoursAreRefused() throws {
        let error = noteError { _ = try NoteStore(url: folder.file()).add("x", color: "purple") }
        #expect(error == .unknownColour("purple"))
        #expect(error?.description == "留言的顏色必須是 yellow, orange, green, blue, red 之一，收到 'purple'")
        #expect(Note.colours == ["yellow", "orange", "green", "blue", "red"])
        #expect(!FileManager.default.fileExists(atPath: folder.file().path))
    }

    @Test(arguments: [
        "{not json",
        #"{"version": 2, "notes": []}"#,
        #"{"notes": []}"#,
        #"{"version": 1}"#,
        #"{"version": 1, "notes": [{"id": "XYZ", "text": "a", "at": "2026-10-12T14:03:00+08:00"}]}"#,
        #"{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "", "at": "2026-10-12T14:03:00+08:00"}]}"#,
        #"{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "a", "at": "yesterday"}]}"#,
        #"{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "a", "at": "2026-10-12T14:03:00"}]}"#,
        #"{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "a", "at": "2026-10-12T14:03:00+08:00", "color": "pink"}]}"#,
        #"{"version": 1, "notes": [{"id": "a1b2c3d4", "text": 5, "at": "2026-10-12T14:03:00+08:00"}]}"#,
        "[1, 2]",
        // beyond the Python cases
        #"{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "a", "at": "2026-10-12T14:03:00+08:00", "color": null}]}"#,
        #"{"version": 1, "notes": [{"id": "a1b2c3d4", "text": " a", "at": "2026-10-12T14:03:00+08:00"}]}"#,
        #"{"version": "1", "notes": []}"#,
        #"{"version": 1, "notes": ["a1b2c3d4"]}"#,
        "\u{FEFF}{\"version\": 1, \"notes\": []}",
        "",
    ])
    func aDamagedFileIsNamedAndNeverOverwritten(content: String) throws {
        let url = folder.file()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        let store = NoteStore(url: url)
        let actions: [() throws -> Void] = [
            { _ = try store.load() }, { _ = try store.add("x") },
            { _ = try store.clear() }, { _ = try store.remove(1) },
        ]
        for action in actions {
            let error = try #require(noteError(action))
            #expect(error.description.contains(url.path), "\(error)")
            #expect(error.message(inChinese: true).contains(url.path), "\(error)")
        }
        #expect(try Data(contentsOf: url) == Data(content.utf8))
    }

    @Test func notUTF8IsUnreadable() throws {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data([0x7B, 0xFF, 0x7D]).write(to: folder.file())
        let error = noteError { _ = try NoteStore(url: folder.file()).load() }
        guard case .unreadableFile(let path, _) = error else { Issue.record("\(String(describing: error))"); return }
        #expect(path == folder.file().path)
        let directory = noteError { _ = try NoteStore(url: folder.url).load() }  // a folder is no file
        guard case .unreadableFile = directory else { Issue.record("\(String(describing: directory))"); return }
    }

    @Test func duplicateIDsInTheFileAreInvalid() throws {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let note = #"{"id": "a1b2c3d4", "text": "a", "at": "2026-10-12T14:03:00+08:00", "color": "yellow"}"#
        try Data(#"{"version": 1, "notes": [\#(note), \#(note)]}"#.utf8).write(to: folder.file())
        let error = noteError { _ = try NoteStore(url: folder.file()).load() }
        #expect(error?.description.contains("invalid") == true, "\(String(describing: error))")
    }

    @Test func aMissingColourInTheFileMeansYellow() throws {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data(#"{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "a", "at": "2026-10-12T14:03:00+08:00"}]}"#.utf8)
            .write(to: folder.file())
        #expect(try NoteStore(url: folder.file()).load()
                == [Note(id: "a1b2c3d4", text: "a", at: "2026-10-12T14:03:00+08:00", color: "yellow")])
    }

    @Test func saveValidates() throws {
        let store = NoteStore(url: folder.file("n.json"))
        #expect(noteError { try store.save([Note(id: "a1b2c3d4", text: "a", at: "2026-10-12T14:03:00+08:00", color: "pink")]) }
                == .unknownColour("pink"))
        #expect(noteError { try store.save([Note(id: "a1b2c3d4", text: " a ", at: "2026-10-12T14:03:00+08:00")]) }
                == .invalidNotes("note a1b2c3d4: text is not normalized"))
        #expect(noteError { try store.save([Note(id: "a1b2c3d4", text: "", at: "2026-10-12T14:03:00+08:00")]) } == .empty)
        #expect(noteError { try store.save([Note(id: "A1B2C3D4", text: "a", at: "2026-10-12T14:03:00+08:00")]) }
                == .invalidNotes("note ids must be 8 hex characters and unique, got 'A1B2C3D4'"))
        #expect(noteError { try store.save([Note(id: "a1b2c3d4", text: "a", at: "2026-10-12T14:03:00")]) }
                == .invalidNotes("note a1b2c3d4: time '2026-10-12T14:03:00' has no UTC offset"))
        let many = (0..<51).map { Note(id: String(format: "%08x", $0), text: "a", at: "2026-10-12T14:03:00+08:00") }
        #expect(noteError { try store.save(many) } == .invalidNotes("at most 50 notes, got 51"))
        #expect(!FileManager.default.fileExists(atPath: folder.file("n.json").path))
    }

    @Test func removeByIDOrByPosition() throws {
        let store = NoteStore(url: folder.file())
        let notes = try three(store)
        let (c, b, a) = (notes[0], notes[1], notes[2])
        #expect(try store.remove(b.id) == b)
        #expect(try store.load() == [c, a])
        #expect(try store.remove(2) == a)  // 1-based, newest first
        #expect(try store.remove(" 1 ") == c)
        #expect(try store.load() == [])
    }

    @Test func removeAcceptsAnIDInCapitals() throws {
        let store = NoteStore(url: folder.file())
        let c = try three(store)[0]
        #expect(try store.remove(c.id.uppercased()) == c)
    }

    @Test func anIDMadeOfDigitsWinsOverAPosition() throws {
        let tokens = Tokens(["00000002", "00000001"])
        let store = NoteStore(url: folder.file(), token: { tokens.next() })
        let older = try store.add("older"), newer = try store.add("newer")
        #expect(try store.remove("00000002") == older)
        #expect(try store.load() == [newer])
    }

    @Test(arguments: ["0", "4", "-1", "zzzzzzzz", "", "99999999999999999999999"])
    func removingAnUnknownNoteRaisesAndKeepsTheFile(key: String) throws {
        let store = NoteStore(url: folder.file())
        _ = try three(store)
        let before = try Data(contentsOf: folder.file())
        let error = noteError { _ = try store.remove(key) }
        #expect(error == .noSuchNote(key: key, count: 3))
        #expect(error?.description == "沒有這則留言：\(key)（請用留言的代碼，或 1 到 3 的編號）")
        #expect(try Data(contentsOf: folder.file()) == before)
        #expect(noteError { _ = try store.remove(0) } == .noSuchNote(key: "0", count: 3))
    }

    @Test func removingFromAnEmptyBoard() throws {
        let error = noteError { _ = try NoteStore(url: folder.file()).remove(1) }
        #expect(error == .noNotes && error?.description == "目前沒有留言")
    }

    @Test func clear() throws {
        let store = NoteStore(url: folder.file())
        #expect(try store.clear() == 0 && !FileManager.default.fileExists(atPath: folder.file().path))
        _ = try three(store)
        #expect(try store.clear() == 3)
        #expect(try store.load() == [] && (try text(of: folder.file())) == "{\n \"version\": 1,\n \"notes\": []\n}")
    }

    // MARK: Against the Python reference

    @Test func textRulesMatchPython() throws {
        let cases = try Expectations.load().texts
        #expect(cases.count == 33)
        for c in cases {
            let label = c.text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
            #expect(Note.normalize(c.text).unicodeScalars.elementsEqual(c.normalized.unicodeScalars), "\(label)")
            do {
                let checked = try Note.checkText(c.text)
                #expect(c.checked.map { checked.unicodeScalars.elementsEqual($0.unicodeScalars) } == true, "\(label)")
            } catch let error as NoteError {
                #expect(error.description == c.error, "\(label)")
            }
        }
    }

    @Test func whitespaceIsPythonsIsspace() throws {
        let python = Set(try Expectations.load().whitespace)
        #expect(python.count == 29)
        let scalars = (0...0x10FFFF).compactMap { Unicode.Scalar(UInt32($0)) }
        let swift = Set(scalars.filter(Note.isPythonSpace).map(\.value))
        #expect(swift == python)
    }

    @Test func theFileIsWrittenAsPythonWritesIt() throws {
        let expected = try Expectations.load().notesFiles
        #expect(expected.colours == Note.colours && expected.maxNotes == NoteStore.maxNotes)
        #expect(expected.maxText == Note.maxText && expected.maxLines == Note.maxLines)
        let store = NoteStore(url: folder.file())
        let notes = expected.notes.map { Note(id: $0.id, text: $0.text, at: $0.at, color: $0.color) }
        try store.save(notes)
        #expect(try text(of: folder.file()) == expected.file)
        #expect(try store.load() == notes)
        try store.save([])
        #expect(try text(of: folder.file()) == expected.emptyFile)
        // and a file the Python reference wrote reads back the same
        try Data(expected.file.utf8).write(to: folder.file())
        #expect(try store.load() == notes)
    }

    // MARK: Note values and messages

    @Test func notesKeepTheirTimeAsWrittenAndParsed() throws {
        let note = Note(id: "a1b2c3d4", text: "x", at: "2026-10-11T17:05:00+00:00")
        #expect(note.at == "2026-10-11T17:05:00+00:00" && note.color == "yellow")
        #expect(note.written == OffsetDateTime(wall(2026, 10, 11, 17, 5), utcOffset: 0))
        #expect(note.written?.utcOffset == 0)
        #expect(note.time(in: tpe) == wall(2026, 10, 12, 1, 5))  // 10/12 01:05
        #expect(note.time(in: utc) == wall(2026, 10, 11, 17, 5))  // 10/11 17:05
        #expect(Note(id: "a1b2c3d4", text: "x", at: "nonsense").time(in: tpe) == nil)
    }

    @Test func errorsInBothLanguages() {
        let all: [NoteError] = [
            .empty, .tooLong(count: 301), .tooManyLines, .unknownColour("it's"),
            .unreadableFile(path: "/x/notes.json", reason: "r"), .invalidFile(path: "/x/notes.json", reason: "r"),
            .invalidNotes("r"), .cannotSave(path: "/x/notes.json", reason: "r"), .noSuchNote(key: "9", count: 3),
            .noNotes,
        ]
        for error in all {
            let chinese = error.message(inChinese: true), english = error.message(inChinese: false)
            #expect(chinese != english, "\(error)")
            let ascii = english.unicodeScalars.allSatisfy { $0.isASCII }
            #expect(ascii, "\(english)")
            #expect(error.errorDescription == chinese)
        }
        #expect(NoteError.tooLong(count: 301).description == "留言最多 300 字（目前 301 字）")
        #expect(NoteError.tooManyLines.description == "留言最多 8 行")
        #expect(NoteError.unknownColour("it's").description.hasSuffix("收到 \"it's\""))
        #expect(NoteError.invalidFile(path: "/x/notes.json", reason: "r").description == "the notes file /x/notes.json is invalid: r")
        #expect(NoteError.unreadableFile(path: "/x/notes.json", reason: "r").description == "cannot read the notes file /x/notes.json: r")
        #expect(pythonRepr("a'b\"c\\\n\u{0}\u{200B}é") == #"'a\'b"c\\\n\x00\u200bé'"#)
    }
}
