import Foundation
import PaperhueAgenda
import PaperhuePages
import Testing
import UlaniKit
@testable import PaperhueUI

// The desktop model: editing never touches the device; 推送到裝置 sends every page with content,
// 更新這頁 one page, 立即同步 the calendar pages; notes, sources and the schedule only save.

private let zone = TimeZone(identifier: "Asia/Taipei")!
private let noon = OffsetDateTime(iso: "2026-10-12T12:00:00+08:00")!
private let address = "https://calendar.example.com/private-0123456789abcdef/basic.ics"
private let ics = """
    BEGIN:VCALENDAR
    VERSION:2.0
    X-WR-CALNAME:家庭
    BEGIN:VEVENT
    UID:e1
    DTSTART:20261012T060000Z
    DTEND:20261012T070000Z
    SUMMARY:牙醫
    END:VEVENT
    BEGIN:VTODO
    UID:t1
    SUMMARY:繳電費
    END:VTODO
    END:VCALENDAR
    """

@MainActor
@Suite final class PageContentTests {
    let keepAwake = FakeKeepAwake()
    let defaults = TestDefaults(pages: [1: .month, 2: .board, 3: .photo, 4: .todo])
    let folder: URL
    let secrets = MemoryFeedSecrets()
    let agent = FakeAgent()

    init() throws {
        folder = try temporaryDirectory()
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    var notes: NoteStore { NoteStore(url: folder.appendingPathComponent("notes.json")) }

    func pageSync(_ loader: TableLoader) -> PageSync {
        PageSync(notes: notes, secrets: secrets, loader: loader, zone: zone, now: { noon.instant })
    }

    func makeModel(_ service: FakePushService = FakePushService(), loader: TableLoader = TableLoader()) -> PushViewModel {
        PushViewModel(service: service, keepAwake: keepAwake, defaults: defaults.defaults,
                      preferredLanguages: ["zh-Hant-TW"], pageSync: pageSync(loader), agent: agent)
    }

    /// The model with one source (address in `secrets`) and a photo on page 3.
    func setUp(_ service: FakePushService, loader: TableLoader) async throws -> PushViewModel {
        let model = makeModel(service, loader: loader)
        secrets.set(FeedSecret(url: address), for: "f1")
        model.settings.feeds = [Feed(id: "f1", name: "家庭")]
        model.load(photo(TestImages.red), into: 3)
        await model.waitForRenders()
        return model
    }

    // MARK: page kinds

    @Test func kindsComeFromTheSettingsAndChangesAreKeptWithoutTouchingTheDevice() async throws {
        let service = FakePushService()
        let model = makeModel(service)
        #expect(model.pages.map(\.kind) == [.month, .board, .photo, .todo])
        #expect(model.page(2).drawing != nil)  // the board, drawn at once from the (empty) notes
        #expect(model.page(1).drawing == nil && model.tileText(model.page(1)).contains("推送或同步時讀取行事曆"))

        model.setKind(.message, for: 1)
        #expect(model.page(1).drawing != nil)
        #expect(try PageSettings.load(from: defaults.reopened()).pages[1] == .message)
        #expect(await service.pushed.isEmpty)
    }

    @Test func aPhotoPageKeepsItsPhotoWhileItShowsSomethingElse() async throws {
        let model = makeModel()
        model.load(photo(TestImages.red), into: 3)
        await model.waitForRenders()
        model.setKind(.todo, for: 3)
        #expect(model.frames().isEmpty)  // not a photo page now
        model.setKind(.photo, for: 3)
        #expect(model.frames().keys.sorted() == [3] && model.page(3).status == .previewReady)
    }

    // MARK: push

    @Test func pushSendsEveryPageWithContentInOneConnection() async throws {
        let service = FakePushService()
        let loader = TableLoader([address: ics])
        let model = try await setUp(service, loader: loader)
        try notes.add("晚餐在冰箱")
        #expect(model.canPush)
        await model.push()

        let pushed = try #require(await service.pushed.first)
        #expect(await service.pushed.count == 1 && pushed.keys.sorted() == [1, 2, 3, 4])
        #expect(loader.calls == 1)
        let today = LocalDate(year: 2026, month: 10, day: 12)!
        let data = try await Feeds.fetch([Feed(id: "f1", name: "家庭")], today: today, zone: zone, now: noon,
                                         secrets: secrets, loader: TableLoader([address: ics]))
        #expect(pushed[1] == (try Frame(indices: CalendarPages.month(data, today: today, zone: zone).indices)))
        #expect(pushed[2] == (try Frame(indices: BoardPages.board(try notes.load(), zone: zone).indices)))
        #expect(pushed[3] == model.page(3).frame)
        #expect(model.skipped.isEmpty && model.summaryText == "完成：4 頁已更新，0 頁原本就相同。")
        #expect(model.page(1).drawing != nil && model.page(4).drawing != nil)  // the previews follow
    }

    @Test func calendarPagesThatCannotBeReadAreLeftOutAndTheRestStillGoes() async throws {
        let service = FakePushService()
        let model = try await setUp(service, loader: TableLoader())  // the source cannot be reached
        await model.push()

        #expect(await service.pushed.first?.keys.sorted() == [2, 3])
        #expect(model.skipped.map(\.pages) == [[1, 4]])
        #expect(model.status(1) == "沒有更新" && model.status(4) == "沒有更新")
        #expect(model.strings.skipped(model.skipped[0])
                == "第 1、4 頁沒有更新：家庭：無法連線到 calendar.example.com（cannotFindHost）")
        #expect(!model.strings.skipped(model.skipped[0]).contains("private-"))
        #expect(model.alert == nil)
    }

    @Test func updateThisPageDrawsAndSendsOnlyThatPage() async throws {
        let service = FakePushService()
        let loader = TableLoader([address: ics])
        let model = try await setUp(service, loader: loader)
        #expect(model.canPush(page: model.page(2)))
        await model.push(page: 2)
        #expect(await service.pushed.map { $0.keys.sorted() } == [[2]])
        #expect(loader.calls == 0)  // a board page needs no calendar
        await model.push(page: 4)
        #expect(await service.pushed.map { $0.keys.sorted() } == [[2], [4]])
        #expect(loader.calls == 1)
    }

    // MARK: sync

    @Test func syncNowSendsTheCalendarPagesOnly() async throws {
        let service = FakePushService()
        let model = try await setUp(service, loader: TableLoader([address: ics]))
        #expect(model.canSync)
        await model.syncNow()
        #expect(await service.pushed.map { $0.keys.sorted() } == [[1, 4]])
        #expect(model.summaryText == "同步完成：2 頁已更新，0 頁原本就相同。")
        #expect(model.deviceStatus == .justSynced)
    }

    @Test func aSyncThatCannotReadTheCalendarsSendsNothing() async throws {
        let service = FakePushService()
        let model = try await setUp(service, loader: TableLoader())
        await model.syncNow()
        #expect(await service.pushed.isEmpty)
        #expect(model.alertTitle == "同步失敗")
        #expect(model.alertMessage == "家庭：無法連線到 calendar.example.com（cannotFindHost）")
        model.setLanguage(.english)
        #expect(model.alertMessage == "家庭: Cannot connect to calendar.example.com (cannotFindHost)")
    }

    // MARK: notes, sources, schedule

    @Test func notesOnlySaveAndRedrawTheBoard() async throws {
        let service = FakePushService()
        let model = makeModel(service)
        let empty = model.page(2).drawing
        #expect(model.addNote("記得澆花", color: "green") == nil)
        #expect(model.notes.map(\.text) == ["記得澆花"] && model.page(2).drawing != empty)
        #expect(model.addNote("   ", color: "green") == .note(.empty))
        #expect(model.removeNote(id: model.notes[0].id) == nil && model.notes.isEmpty)
        _ = model.addNote("一", color: "red")
        _ = model.addNote("二", color: "blue")
        #expect(model.clearNotes() == nil && model.notes.isEmpty)
        #expect(await service.pushed.isEmpty)
    }

    @Test func aSourceIsCheckedThenKeptAndShowsOnlyItsHost() async throws {
        let model = makeModel(loader: TableLoader([address: ics]))
        guard case .success(let added) = await model.addFeed(name: "", url: address, user: "", password: "",
                                                              color: "blue") else {
            Issue.record("not added")
            return
        }
        #expect(added == ("家庭", 1, 1))  // the calendar's own name
        let feed = try #require(model.settings.feeds.first)
        #expect(model.host(of: feed) == "calendar.example.com")
        #expect(try PageSettings.load(from: defaults.reopened()).feeds == [feed])
        #expect(secrets.get(feed.id)?.url == address)
        #expect(model.removeFeed(feed) == nil && model.settings.feeds.isEmpty && secrets.get(feed.id) == nil)

        let failed = await makeModel(loader: TableLoader()).addFeed(name: "x", url: "ftp://nope", user: "",
                                                                    password: "", color: "")
        #expect(failed.map { _ in true } == .failure(.feed(.notAnAddress)))
    }

    @Test func theScheduleNeedsATimeAndRegistersTheAgent() throws {
        let model = makeModel()
        #expect(model.setSchedule([]) == nil && agent.log.isEmpty)  // at least one time
        #expect(model.setSchedule(["17:00", "07:30", "07:30"]) == nil)
        #expect(model.settings.schedule == ["07:30", "17:00"] && agent.log == ["register"])
        #expect(try PageSettings.load(from: defaults.reopened()).schedule == ["07:30", "17:00"])
        #expect(defaults.defaults.object(forKey: ScheduledSync.lastCheckKey) as? Date == noon.instant)
        #expect(model.turnScheduleOff() == nil && model.settings.schedule.isEmpty)
        #expect(agent.log == ["register", "unregister"])
    }
}

@Suite struct ScheduledSyncTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()

    func at(_ iso: String) -> Date { OffsetDateTime(iso: iso)!.instant }

    @Test func dueWhenADailyTimeHasPassedSinceTheLastCheck() {
        let times = ["07:00", "17:00"]
        #expect(ScheduledSync.latest(times, atOrBefore: at("2026-10-13T08:00:00+08:00"), calendar: calendar)
                == at("2026-10-13T07:00:00+08:00"))
        #expect(ScheduledSync.latest(times, atOrBefore: at("2026-10-13T06:59:00+08:00"), calendar: calendar)
                == at("2026-10-12T17:00:00+08:00"))  // yesterday's last
        let cases: [(last: String?, now: String, due: Bool)] = [
            ("2026-10-13T06:50:00+08:00", "2026-10-13T07:05:00+08:00", true),
            ("2026-10-13T07:05:00+08:00", "2026-10-13T07:20:00+08:00", false),
            ("2026-10-12T17:10:00+08:00", "2026-10-13T09:30:00+08:00", true),  // asleep at 07:00: made up once
            ("2026-10-12T16:00:00+08:00", "2026-10-13T09:30:00+08:00", true),  // two missed: one sync
            (nil, "2026-10-13T07:05:00+08:00", false),  // never checked: starts now
        ]
        for c in cases {
            #expect(ScheduledSync.isDue(times, lastCheck: c.last.map(at), now: at(c.now), calendar: calendar) == c.due,
                    "\(c)")
        }
    }

    @Test func aDueRunSyncsTheCalendarPagesAndKeepsTheOutcome() async throws {
        let defaults = TestDefaults(pages: [1: .month, 2: .board, 3: .photo, 4: .photo])
        try PageSettings(pages: [1: .month, 2: .board, 3: .photo, 4: .photo], schedule: ["07:00"]).save(to: defaults.defaults)
        defaults.defaults.set(at("2026-10-13T06:50:00+08:00"), forKey: ScheduledSync.lastCheckKey)
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = at("2026-10-13T07:05:00+08:00")
        let sync = PageSync(notes: NoteStore(url: folder.appendingPathComponent("notes.json")),
                            secrets: MemoryFeedSecrets(),
                            loader: TableLoader([PageSync.defaultCalendarURL: ics]), zone: calendar.timeZone,
                            now: { now })
        let service = FakePushService()
        await ScheduledSync.run(defaults: defaults.defaults, sync: sync, service: service, calendar: calendar)
        #expect(await service.pushed.map { $0.keys.sorted() } == [[1]])  // never the board
        #expect(ScheduledSync.lastOutcome(defaults: defaults.defaults) == ScheduledSync.Outcome(at: now, failure: nil))

        await ScheduledSync.run(defaults: defaults.defaults, sync: sync, service: service, calendar: calendar)
        #expect(await service.pushed.count == 1)  // checked at 07:05: not due again
    }
}
