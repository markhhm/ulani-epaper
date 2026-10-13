import Foundation
import PaperhueAgenda
import Testing
@testable import PaperhuePages

/// python/tests/test_config.py for what the Apple app keeps: the page kinds and the feeds (no
/// sync times, language or device address), in UserDefaults. Each test gets its own suite of
/// defaults, named by a path so that its plist lives in a temporary folder (one in
/// ~/Library/Preferences would stay behind), removed afterwards.
@Suite final class PageSettingsTests: @unchecked Sendable {  // UserDefaults is thread-safe
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("paperhue-settings-\(UUID().uuidString)", isDirectory: true)
    private let defaults: UserDefaults

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: folder.appendingPathComponent("defaults").path))
    }

    deinit {
        defaults.removePersistentDomain(forName: folder.appendingPathComponent("defaults").path)
        try? FileManager.default.removeItem(at: folder)
    }

    private func keep(_ json: String) { defaults.set(Data(json.utf8), forKey: PageSettings.defaultsKey) }

    @Test func defaultsWhenNothingIsKept() throws {
        let s = try PageSettings.load(from: defaults)
        #expect(s.pages == [1: .month, 2: .agenda, 3: .todo, 4: .photo])
        #expect(s.feeds.isEmpty)
    }

    @Test func roundTripKeepsNamesAndColoursButNoAddress() throws {
        let s = PageSettings(pages: [1: .todo, 2: .photo, 3: .message, 4: .board],
                             feeds: [Feed(id: "a1b2c3d4", name: "個人", color: "blue"), Feed(id: "e5f6a7b8", name: "學校")])
        try s.save(to: defaults)
        #expect(try PageSettings.load(from: defaults) == s)
        let data = try #require(defaults.data(forKey: PageSettings.defaultsKey))
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["pages"] as? [String: String] == ["1": "todo", "2": "photo", "3": "message", "4": "board"])
        #expect((raw["feeds"] as? [[String: String]])?.first == ["id": "a1b2c3d4", "name": "個人", "color": "blue"])
        #expect(!String(decoding: data, as: UTF8.self).contains("url"))  // the address is a secret: never kept here
    }

    @Test(arguments: [
        PageSettings(pages: [5: .month]),
        PageSettings(feeds: [Feed(id: "a1", name: "x", color: "purple")]),
        PageSettings(feeds: [Feed(id: "a1", name: "x"), Feed(id: "a1", name: "y")]),
        PageSettings(feeds: [Feed(id: "", name: "x")]),
        PageSettings(feeds: [Feed(id: "a1", name: " ")]),
    ])
    func invalidSettingsAreRefusedAndNotKept(settings: PageSettings) {
        #expect(throws: (any Error).self) { try settings.save(to: self.defaults) }
        #expect(defaults.object(forKey: PageSettings.defaultsKey) == nil)
    }

    @Test func missingPagesKeepTheirDefaults() throws {
        keep(#"{"pages": {"4": "todo"}}"#)
        #expect(try PageSettings.load(from: defaults).pages == [1: .month, 2: .agenda, 3: .todo, 4: .todo])
    }

    @Test(arguments: [#"{not json"#, #"{"pages": {"1": "weather"}}"#, #"{"pages": {"5": "month"}}"#,
                      #"{"feeds": [{"id": "a1", "name": " ", "color": ""}]}"#])
    func unreadableSettingsAreReportedAndLeftAsTheyAre(json: String) {
        keep(json)
        #expect(throws: PageSettingsError.unreadable) { try PageSettings.load(from: self.defaults) }
        #expect(defaults.data(forKey: PageSettings.defaultsKey) == Data(json.utf8))
    }

    @Test func scheduleTimesAreKeptAndChecked() throws {
        let s = PageSettings(schedule: ["07:30", "17:00"])
        try s.save(to: defaults)
        #expect(try PageSettings.load(from: defaults).schedule == ["07:30", "17:00"])
        #expect(PageSettings.minutes("07:30") == 450 && PageSettings.minutes("23:59") == 1439)
        for bad in ["7:30", "24:00", "12:60", "12-00", "", "１２:00"] {
            #expect(PageSettings.minutes(bad) == nil, "\(bad)")
            #expect(throws: PageSettingsError.invalidTime(bad)) { try PageSettings(schedule: [bad]).validate() }
        }
    }

    @Test func pageKinds() {
        #expect(PageKind.allCases.map(\.rawValue) == ["photo", "month", "agenda", "todo", "day", "monthgrid", "board",
                                                        "message"])
        #expect(PageKind.allCases.filter(\.isCalendar) == [.month, .agenda, .todo, .day, .monthgrid])
        #expect(PageKind.allCases.filter(\.isBoard) == [.board, .message])
    }
}
