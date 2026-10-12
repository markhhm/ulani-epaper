import Foundation
import PaperhueAgenda
import Testing
import UlaniKit
@testable import PaperhuePages

// python/tests/test_sync.py with the real pages: every frame pushed must be the page's own
// drawing of the fetched data or the saved notes, palette indices as drawn (no dither).
// No network (a table of bodies), no Keychain, no device (a fake push).

/// Neither this Mac's zone nor UTC, so a page drawn in either would differ.
private let zone = TimeZone(identifier: "Pacific/Honolulu")!
private let now = OffsetDateTime(iso: "2026-10-12T09:00:30-10:00")!
private let today = LocalDate(year: 2026, month: 10, day: 12)!
/// A Google secret address: its path is the secret.
private let address = "https://calendar.google.com/calendar/ical/me%40gmail.com/private-0123456789abcdef/basic.ics"
private let personal = Feed(id: "p1", name: "個人")
/// One event today and one open to-do.
private let ics = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:e1
    DTSTART:20261012T200000Z
    DTEND:20261012T210000Z
    SUMMARY:牙醫
    END:VEVENT
    BEGIN:VTODO
    UID:t1
    SUMMARY:繳電費
    DUE;VALUE=DATE:20261014
    END:VTODO
    END:VCALENDAR
    """

/// Answers each address from a table and counts the calls; an address not in it cannot be reached.
private final class TableLoader: FeedLoader, @unchecked Sendable {
    private let lock = NSLock()
    private let bodies: [String: String]
    private var count = 0

    init(_ bodies: [String: String] = [:]) { self.bodies = bodies }

    var calls: Int { lock.withLock { count } }

    func load(_ url: String, user: String, password: String) async throws -> Data {
        lock.withLock { count += 1 }
        guard let body = bodies[url] else { throw URLError(.cannotFindHost) }
        return Data(body.utf8)
    }
}

/// Stands in for the device: keeps every push with its page to show, sends one progress event
/// and finds every page changed. `log` has "push" for each push, and whatever the test adds.
private final class FakeDevice: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(frames: [Int: Frame], show: Int?)] = []
    private var lines: [String] = []
    private var shown: [Int: Frame]?

    var pushes: [(frames: [Int: Frame], show: Int?)] { lock.withLock { recorded } }
    var log: [String] { lock.withLock { lines } }
    /// What the sync handed over as its drawings.
    var drawings: [Int: Frame]? { lock.withLock { shown } }

    func note(_ line: String) { lock.withLock { lines.append(line) } }

    /// For `drawn`: keeps the drawings and logs "drawn [pages]".
    func drew(_ frames: [Int: Frame]) {
        lock.withLock {
            shown = frames
            lines.append("drawn \(frames.keys.sorted())")
        }
    }

    var push: PageSync.Push {
        { frames, show, progress in
            self.lock.withLock {
                self.recorded.append((frames, show))
                self.lines.append("push")
            }
            progress?(PushEvent(page: frames.keys.min() ?? 0, phase: .done, index: 0, count: frames.count))
            return frames.mapValues { _ in .ok }
        }
    }
}

private func frame(_ page: PageCanvas) throws -> Frame { try Frame(indices: page.indices) }

/// The error `body` throws, or nil.
private func thrown(_ body: () async throws -> Void) async -> (any Error)? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

@Suite final class PageSyncTests: Sendable {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("paperhue-sync-\(UUID().uuidString)", isDirectory: true)
    private let device = FakeDevice()

    deinit { try? FileManager.default.removeItem(at: folder) }

    private var notes: NoteStore { NoteStore(url: folder.appendingPathComponent("notes.json")) }

    private func engine(_ loader: TableLoader) -> PageSync {
        PageSync(notes: notes, push: device.push, secrets: MemoryFeedSecrets(["p1": FeedSecret(url: address)]),
                 loader: loader, zone: zone, now: { now.instant })
    }

    /// What the feeds give, read as the sync must read them: in `zone`, on `now`'s day.
    private func fetched() async throws -> AgendaData {
        try await Feeds.fetch([personal], today: today, zone: zone, now: now,
                              secrets: MemoryFeedSecrets(["p1": FeedSecret(url: address)]), loader: TableLoader([address: ics]))
    }

    private func saveNote() throws -> Note {
        try notes.add("晚餐在冰箱", now: OffsetDateTime(iso: "2026-10-12T14:03:00+08:00")!)
    }

    // MARK: sync

    @Test func syncDrawsTheCalendarPagesFromTheFeedsAndPushesThemTogether() async throws {
        let loader = TableLoader([address: ics])
        let report = try await engine(loader).sync(PageSettings(feeds: [personal]),
                                                   progress: { self.device.note("\($0.page) \($0.phase.rawValue)") })
        let data = try await fetched()
        #expect(data.events.count == 1 && data.tasks.count == 1)
        #expect(loader.calls == 1)
        let push = try #require(device.pushes.first)
        #expect(device.pushes.count == 1 && push.show == nil)  // a sync never switches the display
        #expect(push.frames == [1: try frame(CalendarPages.month(data, today: today, zone: zone)),
                                2: try frame(CalendarPages.agenda(data, today: today, zone: zone)),
                                3: try frame(CalendarPages.todo(data, today: today, zone: zone))])  // page 4 is a photo
        #expect(device.log == ["push", "1 done"])
        #expect(report == SyncReport(pages: [1: .month, 2: .agenda, 3: .todo], events: 1, tasks: 1,
                                     results: [1: .ok, 2: .ok, 3: .ok]))
    }

    @Test func theDrawingsAreHandedOverBeforeThePush() async throws {
        _ = try await engine(TableLoader([address: ics])).sync(PageSettings(feeds: [personal]), drawn: device.drew)
        #expect(device.log == ["drawn [1, 2, 3]", "push"])
        #expect(device.drawings == device.pushes.first?.frames)
    }

    @Test func nothingToDoWithOnlyPhotoPages() async throws {
        let loader = TableLoader([address: ics])
        let report = try await engine(loader).sync(PageSettings(pages: [1: .photo, 2: .photo, 3: .photo, 4: .photo],
                                                                feeds: [personal]))
        #expect(report == SyncReport())
        #expect(loader.calls == 0 && device.pushes.isEmpty)
    }

    @Test func aFeedThatCannotBeReadStopsTheSyncBeforeThePushAndNamesOnlyItsHost() async throws {
        let error = await thrown { _ = try await self.engine(TableLoader()).sync(PageSettings(feeds: [personal])) }
        #expect(error as? FeedError == .inFeed(name: "個人", .cannotConnect(host: "calendar.google.com",
                                                                            reason: "cannotFindHost")))
        #expect(!String(describing: try #require(error)).contains("private-"))
        #expect(device.pushes.isEmpty)
    }

    @Test func aBoardOnlySetupNeedsNoFeeds() async throws {
        let note = try saveNote()
        let loader = TableLoader()
        let report = try await engine(loader).sync(PageSettings(pages: [1: .photo, 2: .board, 3: .photo, 4: .message]))
        #expect(loader.calls == 0)  // no feeds at all: fetching them would fail
        let push = try #require(device.pushes.first)
        #expect(push.show == nil)
        #expect(push.frames == [2: try frame(BoardPages.board([note], zone: zone)),
                                4: try frame(BoardPages.message([note], zone: zone))])
        #expect(report == SyncReport(pages: [2: .board, 4: .message], notes: 1, results: [2: .ok, 4: .ok]))
    }

    @Test func aMixedSetupFetchesTheFeedsOnceAndDrawsTheSavedNotes() async throws {
        let note = try saveNote()
        let loader = TableLoader([address: ics])
        let report = try await engine(loader).sync(PageSettings(pages: [1: .month, 2: .board, 3: .todo, 4: .photo],
                                                                feeds: [personal]))
        #expect(loader.calls == 1)
        let frames = try #require(device.pushes.first).frames
        #expect(frames.keys.sorted() == [1, 2, 3])
        #expect(frames[2] == (try frame(BoardPages.board([note], zone: zone))))
        #expect(report.notes == 1 && report.events == 1 && report.tasks == 1)
    }

    @Test func aDamagedNotesFileStopsTheSyncBeforeAnythingIsFetchedOrPushed() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: notes.url)
        let loader = TableLoader([address: ics])
        let error = await thrown {
            _ = try await self.engine(loader).sync(PageSettings(pages: [1: .month, 2: .board, 3: .photo, 4: .photo],
                                                                feeds: [personal]))
        }
        #expect(error is NoteError)
        #expect(loader.calls == 0 && device.pushes.isEmpty)
        #expect(try Data(contentsOf: notes.url) == Data("{broken".utf8))
    }

    // MARK: post

    @Test(arguments: [
        ([1: .month, 2: .board, 3: .message, 4: .board], .auto, 3),  // the big message first
        ([1: .month, 2: .board, 3: .photo, 4: .board], .auto, 2),
        ([1: .month, 2: .board, 3: .message, 4: .board], .board, 2),
        ([1: .message, 2: .board, 3: .message, 4: .board], .message, 1),
        ([1: .month, 2: .board, 3: .photo, 4: .photo], .message, 2),  // none of that kind: the auto choice
        ([1: .month, 2: .board, 3: .message, 4: .board], .none, nil),
    ] as [([Int: PageKind], PageSync.Show, Int?)])
    func postPushesOnlyTheBoardPagesAndSwitches(pages: [Int: PageKind], show: PageSync.Show, target: Int?) async throws {
        let note = try saveNote()
        let loader = TableLoader([address: ics])
        let report = try await engine(loader).post(PageSettings(pages: pages, feeds: [personal]), show: show)
        let boards = pages.filter { $0.value.isBoard }
        let push = try #require(device.pushes.first)
        #expect(device.pushes.count == 1 && push.show == target)
        #expect(push.frames == (try boards.mapValues { kind in
            try frame(kind == .board ? BoardPages.board([note], zone: zone) : BoardPages.message([note], zone: zone))
        }))
        #expect(loader.calls == 0)  // works offline
        #expect(report == SyncReport(pages: boards, notes: 1, results: boards.mapValues { _ in .ok }, show: target))
    }

    @Test func postWithoutABoardPageSaysSo() async throws {
        let error = await thrown { _ = try await self.engine(TableLoader()).post(PageSettings()) }
        #expect(error as? SyncError == .noBoardPage)
        #expect(device.pushes.isEmpty)
    }
}
