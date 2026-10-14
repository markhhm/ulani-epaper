import CoreGraphics
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

/// Stands in for the device: keeps every push, sends one progress event and finds every page
/// changed. `log` has "push" for each push, and whatever the test adds.
private final class FakeDevice: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[Int: Frame]] = []
    private var lines: [String] = []
    private var shown: [Int: Frame]?

    var pushes: [[Int: Frame]] { lock.withLock { recorded } }
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
        { frames, progress in
            self.lock.withLock {
                self.recorded.append(frames)
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
        PageSync(notes: notes, secrets: MemoryFeedSecrets(["p1": FeedSecret(url: address)]),
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

    // MARK: sync (立即同步, the scheduled sync)

    @Test func syncDrawsTheCalendarPagesFromTheFeedsAndPushesThemTogether() async throws {
        let loader = TableLoader([address: ics])
        let settings = PageSettings(pages: [1: .month, 2: .agenda, 3: .todo, 4: .board], feeds: [personal])
        let report = try await engine(loader).sync(settings, push: device.push,
                                                   progress: { self.device.note("\($0.page) \($0.phase.rawValue)") })
        let data = try await fetched()
        #expect(data.events.count == 1 && data.tasks.count == 1)
        #expect(loader.calls == 1)
        #expect(device.pushes == [[1: try frame(CalendarPages.month(data, today: today, zone: zone)),
                                   2: try frame(CalendarPages.agenda(data, today: today, zone: zone)),
                                   3: try frame(CalendarPages.todo(data, today: today, zone: zone))]])  // never the board
        #expect(device.log == ["push", "1 done"])
        #expect(report == SyncReport(pages: [1: .month, 2: .agenda, 3: .todo], events: 1, tasks: 1,
                                     results: [1: .ok, 2: .ok, 3: .ok]))
    }

    @Test func theDrawingsAreHandedOverBeforeThePush() async throws {
        _ = try await engine(TableLoader([address: ics])).sync(PageSettings(feeds: [personal]), push: device.push,
                                                               drawn: device.drew)
        #expect(device.log == ["drawn [1, 2, 3]", "push"])
        #expect(device.drawings == device.pushes.first)
    }

    @Test(arguments: [[1: .photo, 2: .photo, 3: .photo, 4: .photo], [1: .board, 2: .message, 3: .photo, 4: .photo]]
          as [[Int: PageKind]])
    func nothingToDoWithoutACalendarPage(pages: [Int: PageKind]) async throws {
        let loader = TableLoader([address: ics])
        let report = try await engine(loader).sync(PageSettings(pages: pages, feeds: [personal]), push: device.push)
        #expect(report == SyncReport())
        #expect(loader.calls == 0 && device.pushes.isEmpty)
    }

    @Test func aFeedThatCannotBeReadStopsTheSyncBeforeThePushAndNamesOnlyItsHost() async throws {
        let error = await thrown {
            _ = try await self.engine(TableLoader()).sync(PageSettings(feeds: [personal]), push: self.device.push)
        }
        #expect(error as? FeedError == .inFeed(name: "個人", .cannotConnect(host: "calendar.google.com",
                                                                            reason: "cannotFindHost")))
        #expect(!String(describing: try #require(error)).contains("private-"))
        #expect(device.pushes.isEmpty)
    }

    @Test func theDayAndMonthPagesAreDrawnLikeTheOthers() async throws {
        let drawing = try await engine(TableLoader([address: ics])).drawCalendar([1: .day, 2: .monthgrid, 3: .photo],
                                                                                  feeds: [personal])
        let data = try await fetched()
        #expect(drawing.frames == [1: try frame(CalendarPages.day(data, today: today, zone: zone)),
                                   2: try frame(CalendarPages.monthGrid(data, today: today, zone: zone))])
    }

    @Test func withoutSourcesTheTaiwanHolidaysAreRead() async throws {
        let loader = TableLoader([PageSync.defaultCalendarURL: ics])
        let drawing = try await engine(loader).drawCalendar([1: .agenda, 2: .photo], feeds: [])
        #expect(loader.calls == 1)
        #expect(drawing.frames.keys.sorted() == [1] && drawing.events == 1 && drawing.tasks == 1)
        let error = await thrown { _ = try await self.engine(TableLoader()).drawCalendar([1: .month], feeds: []) }
        #expect(error as? FeedError == .inFeed(name: "台灣假日", .cannotConnect(host: "calendar.google.com",
                                                                              reason: "cannotFindHost")))
    }

    // MARK: backgrounds

    @Test func calendarPagesAreDrawnOnTheirBackgroundPhoto() async throws {
        let store = BackgroundStore(folder: folder.appendingPathComponent("backgrounds"))
        let photo = try #require(CGContext(data: nil, width: 1200, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        photo.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        photo.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        let kept = try store.keep(try #require(photo.makeImage()), page: 2, crop: Crop(left: 0, top: 0.2, width: 1, height: 0.8))
        #expect(kept == PageBackground(image: "page-2.jpg", crop: Crop(left: 0, top: 0.2, width: 1, height: 0.8)))
        let sync = PageSync(notes: notes, backgrounds: store, secrets: MemoryFeedSecrets(["p1": FeedSecret(url: address)]),
                            loader: TableLoader([address: ics]), zone: zone, now: { now.instant })
        let lost = PageBackground(image: "page-3.jpg")  // no such file
        let drawing = try await sync.drawCalendar([2: .agenda, 3: .todo], feeds: [personal], backgrounds: [2: kept, 3: lost],
                                                  strength: 0.8, colours: .classic)
        let data = try await fetched()
        let background = try store.frame(kept, strength: 0.8, colours: .classic)
        #expect(drawing.frames[2] == (try frame(CalendarPages.agenda(data, today: today, zone: zone, background: background))))
        #expect(drawing.frames[3] == (try frame(CalendarPages.todo(data, today: today, zone: zone))))  // on white
        #expect(drawing.unreadableBackgrounds == [3])
        store.remove(kept)
        #expect(throws: (any Error).self) { try store.frame(kept, strength: 1, colours: .natural) }
    }

    // MARK: board pages

    @Test func boardPagesAreDrawnFromTheSavedNotesWithoutTheNetwork() throws {
        let note = try saveNote()
        let frames = try engine(TableLoader()).drawBoards([1: .month, 2: .board, 3: .photo, 4: .message])
        #expect(frames == [2: try frame(BoardPages.board([note], zone: zone)),
                           4: try frame(BoardPages.message([note], zone: zone))])
        #expect(try engine(TableLoader()).drawBoards([1: .month]).isEmpty)
    }

    @Test func aDamagedNotesFileIsAnErrorAndLeftAsItIs() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: notes.url)
        #expect(throws: NoteError.self) { try self.engine(TableLoader()).drawBoards([2: .board]) }
        #expect(try Data(contentsOf: notes.url) == Data("{broken".utf8))
    }
}
