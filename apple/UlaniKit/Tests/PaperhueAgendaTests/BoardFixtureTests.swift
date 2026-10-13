import Foundation
import Testing
@testable import PaperhueAgenda

/// The message board fixtures in shared/layouts/board/, read as python/tests/test_board_layouts.py
/// reads them, and telling the two kinds of page fixture apart.
@Suite struct BoardFixtureTests {
    @Test(arguments: Repo.boardFixtureNames)
    func everyBoardFixtureLoads(name: String) throws {
        let fixture = try BoardFixture(contentsOf: Repo.boardFixture(name))
        #expect(fixture.utcOffset == "+08:00" && fixture.zone.secondsFromGMT() == 8 * 3600)
        let counts = ["empty": 0, "short": 1, "long": 1, "six": 6, "eight": 8, "emoji": 1]
        #expect(fixture.notes.count == counts[name])
        for note in fixture.notes {
            #expect(NoteStore.isNoteID(note.id), "\(name) \(note.id)")
            #expect(Note.colours.contains(note.color), "\(name) \(note.id)")
            #expect(note.written != nil, "\(name) \(note.id)")
        }
    }

    @Test func boardFixtureValues() throws {
        let short = try BoardFixture(contentsOf: Repo.boardFixture("short")).notes
        #expect(short == [Note(id: "a1b2c3d4", text: "晚餐在冰箱，微波 3 分鐘就好", at: "2026-10-12T14:03:00+08:00")])
        let long = try #require(try BoardFixture(contentsOf: Repo.boardFixture("long")).notes.first)
        #expect(long.at == "2026-10-12T06:30:00+00:00" && long.color == "blue")
        #expect(long.time(in: tpe) == wall(2026, 10, 12, 14, 30))  // drawn as 10/12 14:30
        let six = try BoardFixture(contentsOf: Repo.boardFixture("six")).notes
        #expect(six.map(\.color) == ["red", "green", "yellow", "blue", "orange", "green"])
        #expect(six[0].text == "我去接小孩，\n六點前回來")
        let emoji = try #require(try BoardFixture(contentsOf: Repo.boardFixture("emoji")).notes.first)
        #expect(emoji.text == "🎂🎉\u{2764}\u{FE0F}" && emoji.text.unicodeScalars.count == 4)
    }

    @Test func boardFixturesTakeNotesAsTheyAre() throws {
        let json = #"{"utc_offset": "-03:30", "notes": [{"id": "x", "text": " not normalized ", "at": "2026-10-12T14:03:00"}, {"id": "y", "text": "", "at": "?", "color": "pink"}]}"#
        let fixture = try BoardFixture(json: Data(json.utf8))
        #expect(fixture.zone.secondsFromGMT() == -12_600)
        #expect(fixture.notes[0] == Note(id: "x", text: " not normalized ", at: "2026-10-12T14:03:00", color: "yellow"))
        #expect(fixture.notes[0].written == nil)
        #expect(fixture.notes[0].time(in: tpe) == wall(2026, 10, 12, 14, 3))  // no offset: as written
        #expect(fixture.notes[1].color == "pink" && fixture.notes[1].time(in: tpe) == nil)
    }

    @Test func everyFixtureFileIsReadByKind() throws {
        for (folder, isBoard) in [("shared/layouts/agenda", false), ("shared/layouts/board", true)] {
            let names = try FileManager.default.contentsOfDirectory(atPath: Repo.url(folder).path)
                .filter { $0.hasSuffix(".json") }
            #expect(names.count == (isBoard ? 6 : 5))  // agenda: also photo.json (a background, v0.3.1)
            for name in names {
                switch try LayoutFixture(contentsOf: Repo.url(folder).appendingPathComponent(name)) {
                case .agenda: #expect(!isBoard, "\(name)")
                case .board: #expect(isBoard, "\(name)")
                }
            }
        }
    }

    @Test func badBoardFixturesAreRefused() {
        #expect(throws: FixtureError.self) { try BoardFixture(json: Data(#"{"utc_offset": "+08:00"}"#.utf8)) }
        #expect(throws: FixtureError.self) {
            try BoardFixture(json: Data(#"{"utc_offset": "+08:00", "notes": [{"id": "a", "text": 1, "at": ""}]}"#.utf8))
        }
        #expect(throws: FixtureError.self) { try BoardFixture(json: Data(#"{"notes": []}"#.utf8)) }
    }
}
