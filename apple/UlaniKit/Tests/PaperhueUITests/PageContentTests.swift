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
        PageSync(notes: notes, backgrounds: BackgroundStore(folder: folder.appendingPathComponent("backgrounds")),
                 secrets: secrets, loader: loader, zone: zone, now: { noon.instant })
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

    // MARK: backgrounds

    @Test func aBackgroundIsKeptShownAndDrawnUnderTheCalendarWhenPushed() async throws {
        let service = FakePushService()
        let model = try await setUp(service, loader: TableLoader([address: ics]))
        model.setBackground(photo(TestImages.blue), for: 1)
        await model.waitForRenders()
        #expect(model.settings.backgrounds[1] == PageBackground(image: "page-1.jpg"))
        #expect(try PageSettings.load(from: defaults.reopened()).backgrounds[1] == PageBackground(image: "page-1.jpg"))
        #expect(model.status(1) == "底圖已設定，推送或同步時會畫上這一頁" && model.page(1).drawing != nil)
        #expect(await service.pushed.isEmpty)  // nothing reaches the device yet

        await model.push(page: 1)
        let pushed = try #require(await service.pushed.first?[1])
        let store = BackgroundStore(folder: folder.appendingPathComponent("backgrounds"))
        let today = LocalDate(year: 2026, month: 10, day: 12)!
        let data = try await Feeds.fetch([Feed(id: "f1", name: "家庭")], today: today, zone: zone, now: noon,
                                         secrets: secrets, loader: TableLoader([address: ics]))
        let background = try store.frame(try #require(model.settings.backgrounds[1]), strength: 1)
        #expect(pushed == (try Frame(indices: CalendarPages.month(data, today: today, zone: zone,
                                                                  background: background).indices)))

        let editing = try #require(model.backgroundCropEditing(for: 1))
        #expect(editing.background && editing.page == 1)
        model.clearBackground(page: 1)
        #expect(model.settings.backgrounds.isEmpty && model.page(1).drawing == nil)
        #expect(model.status(1) == "已移除底圖，推送或同步時會更新裝置")
    }

    @Test func aSupersededChoiceLeavesNothingBehind() async throws {
        let model = makeModel()
        model.setBackground(photo(TestImages.blue), for: 1)
        await model.waitForRenders()
        model.setBackground(photo(TestImages.red), for: 1)  // still loading when removed
        model.clearBackground(page: 1)
        await model.waitForRenders()
        #expect(model.settings.backgrounds.isEmpty && !model.page(1).isBusy)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("backgrounds").path)
        #expect(left.isEmpty, "\(left)")
    }

    @Test func aPhotoKeptOnAPageThatShowsACalendarSurvivesAGrainChange() async throws {
        let model = makeModel()
        model.setKind(.photo, for: 1)
        model.load(photo(TestImages.red), into: 1)
        await model.waitForRenders()
        model.setKind(.month, for: 1)
        model.setBackground(photo(TestImages.blue), for: 1)
        await model.waitForRenders()
        model.setGrain(.soft)
        await model.waitForRenders()
        model.setKind(.photo, for: 1)
        #expect(model.page(1).frame != nil && model.canPush(page: model.page(1)))
    }

    @Test func aLostBackgroundIsDrawnWithoutAndSaysSo() async throws {
        let service = FakePushService()
        let model = try await setUp(service, loader: TableLoader([address: ics]))
        model.settings.backgrounds[4] = PageBackground(image: "page-4.jpg")  // the file is gone
        await model.push(page: 4)
        #expect(await service.pushed.count == 1 && model.lostBackgrounds == [4])
        #expect(model.strings.lostBackgrounds(model.lostBackgrounds)
                == "第 4 頁的底圖讀不到，這次沒有底圖；請重新選擇底圖照片。")
    }

    @Test func theGrainSettingIsKept() async throws {
        let model = makeModel()
        model.setGrain(.softer)
        #expect(try PageSettings.load(from: defaults.reopened()).grain == 0.65)
        #expect(makeModel().grain == .softer)
    }

    // MARK: sync

    @Test func syncNowSendsTheCalendarPagesOnly() async throws {
        let service = FakePushService()
        let model = try await setUp(service, loader: TableLoader([address: ics]))
        #expect(model.canSync)
        await model.syncNow()
        #expect(await service.pushed.map { $0.keys.sorted() } == [[1, 4]])
        #expect(model.summaryText == "同步完成：第 1 頁 本日＋月曆：已更新；第 4 頁 待辦清單：已更新（1 個行程、1 項待辦）")
        #expect(model.lastSync?.at == noon.instant && model.lastSync?.failure == nil)
        #expect(model.strings.lastSync(model.lastSync).hasSuffix(" 成功"))
        #expect(model.deviceStatus == .justSynced)
    }

    @Test func aSyncThatCannotReadTheCalendarsSendsNothing() async throws {
        let service = FakePushService()
        let model = try await setUp(service, loader: TableLoader())
        await model.syncNow()
        #expect(await service.pushed.isEmpty)
        #expect(model.alertTitle == "同步失敗")
        #expect(model.alertMessage == "無法讀取行事曆來源。請確認網路連線；如果網址已重設，請在「行事曆來源…」更新。\n\n"
                + "家庭：無法連線到 calendar.example.com（cannotFindHost）")
        #expect(model.lastSync?.failure?.contains("cannotFindHost") == true)
        model.setLanguage(.english)
        #expect(model.alertMessage?.hasSuffix("\n\n家庭: Cannot connect to calendar.example.com (cannotFindHost)") == true)
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
        model.page(1).drawing = model.page(2).drawing  // as if drawn from the old sources
        guard case .success(let added) = await model.addFeed(name: "", url: address, user: "", password: "",
                                                              color: "blue") else {
            Issue.record("not added")
            return
        }
        #expect(added == ("家庭", 1, 1))  // the calendar's own name
        #expect(model.page(1).drawing == nil)  // no longer what a push would send
        let feed = try #require(model.settings.feeds.first)
        #expect(model.host(of: feed) == "calendar.example.com")
        #expect(try PageSettings.load(from: defaults.reopened()).feeds == [feed])
        #expect(secrets.get(feed.id)?.url == address)
        #expect(model.removeFeed(feed) == nil && model.settings.feeds.isEmpty && secrets.get(feed.id) == nil)

        let failed = await makeModel(loader: TableLoader()).addFeed(name: "x", url: "ftp://nope", user: "",
                                                                    password: "", color: "")
        #expect(failed.map { _ in true } == .failure(.feed(.notAnAddress)))
    }

    @Test func aSourceCanBeRenamedOrGivenANewAddress() async throws {
        let other = "https://other.example.org/cal.ics"
        let loader = TableLoader([address: ics, address + "?v=2": ics, other: ics])
        let model = makeModel(loader: loader)
        secrets.set(FeedSecret(url: address, user: "me", password: "pw"), for: "f1")
        model.settings.feeds = [Feed(id: "f1", name: "家庭")]
        let feed = model.settings.feeds[0]
        #expect(model.user(of: feed) == "me")

        guard case .success(let renamed) = await model.editFeed(feed, name: " 家裡 ", url: "", user: "me", password: "",
                                                                 color: "red") else { Issue.record("not saved"); return }
        #expect(renamed.name == "家裡" && renamed.events == nil && loader.calls == 0)  // nothing read
        #expect(model.settings.feeds == [Feed(id: "f1", name: "家裡", color: "red")])

        // Another address on the same host keeps the password; on another host it is not reused.
        _ = await model.editFeed(feed, name: "家裡", url: address + "?v=2", user: "me", password: "", color: "red")
        #expect(secrets.get("f1") == FeedSecret(url: address + "?v=2", user: "me", password: "pw"))
        guard case .success(let moved) = await model.editFeed(feed, name: "家裡", url: other, user: "me", password: "",
                                                               color: "red") else { Issue.record("not saved"); return }
        #expect(moved.events == 1 && secrets.get("f1") == FeedSecret(url: other, user: "me", password: ""))

        #expect(await model.editFeed(feed, name: " ", url: "", user: "", password: "", color: "").map { _ in true }
                == .failure(.feed(.unnamedFeed)))
        // Spaces around the address and user name do not count.
        guard case .success(let spaced) = await model.editFeed(feed, name: "家裡", url: " ", user: " me ", password: "",
                                                                color: "red") else { Issue.record("not saved"); return }
        #expect(spaced.events == nil)
        secrets.delete("f1")
        #expect(model.host(of: feed) == nil)  // the list then says the address is lost
        #expect(await model.editFeed(feed, name: "家裡", url: "", user: "", password: "", color: "").map { _ in true }
                == .failure(.feed(.missingAddress)))  // a lost address needs a new one
    }

    @Test func droppedPhotosFillThePhotoPagesAndCanTurnOthersIntoPhotoPages() async throws {
        let model = makeModel()  // pages: month, board, photo, todo
        let urls = try (1...3).map { i in
            let url = folder.appendingPathComponent("p\(i).png")
            try TestImages.png(TestImages.red).write(to: url)
            return url
        }
        #expect(model.dropConversion(count: 3).map(\.page) == [1, 2])
        #expect(model.loadDropped(urls, convert: false) == 1 && model.partialDrop == 1)
        #expect(model.strings.dropAsk(photos: 3, slots: 1, convert: model.dropConversion(count: 3))
                == "拖進來 3 張照片，但只有 1 頁設為照片。\n要把第 1 頁（本日＋月曆）、第 2 頁（留言板）改成照片嗎？")
        #expect(model.loadDropped(urls, convert: true) == 3 && model.partialDrop == nil)
        #expect(model.pages.map(\.kind) == [.photo, .photo, .photo, .todo])
        await model.waitForRenders()
        #expect(model.frames().keys.sorted() == [1, 2, 3])
    }

    @Test func theScheduleNeedsATimeAndRegistersTheAgent() throws {
        let model = makeModel()
        #expect(model.setSchedule([]) == nil && agent.log.isEmpty)  // at least one time
        #expect(model.setSchedule(["17:00", "07:30", "07:30"]) == nil)
        #expect(model.settings.schedule == ["07:30", "17:00"] && agent.log == ["register"])
        #expect(try PageSettings.load(from: defaults.reopened()).schedule == ["07:30", "17:00"])
        #expect(defaults.defaults.object(forKey: ScheduledSync.lastCheckKey) as? Date == noon.instant)
        // An edit keeps a time that is due still due.
        let earlier = noon.instant.addingTimeInterval(-3600)
        defaults.defaults.set(earlier, forKey: ScheduledSync.lastCheckKey)
        #expect(model.setSchedule(["07:30"]) == nil)
        #expect(defaults.defaults.object(forKey: ScheduledSync.lastCheckKey) as? Date == earlier)
        #expect(model.turnScheduleOff() == nil && model.settings.schedule.isEmpty)
        #expect(agent.log == ["register", "register", "unregister"])
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

    @Test func aFailedSyncIsTriedAgainOnTheNextRunsThreeTimesInAll() async throws {
        let defaults = TestDefaults(pages: [1: .month, 2: .photo, 3: .photo, 4: .photo])
        try PageSettings(pages: [1: .month, 2: .photo, 3: .photo, 4: .photo], schedule: ["07:00"]).save(to: defaults.defaults)
        let before = at("2026-10-13T06:50:00+08:00")
        defaults.defaults.set(before, forKey: ScheduledSync.lastCheckKey)
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = FakePushService()
        func run(_ iso: String, loader: TableLoader) async {
            let now = at(iso)
            let sync = PageSync(notes: NoteStore(url: folder.appendingPathComponent("notes.json")),
                                secrets: MemoryFeedSecrets(), loader: loader, zone: calendar.timeZone, now: { now })
            await ScheduledSync.run(defaults: defaults.defaults, sync: sync, service: service, calendar: calendar)
        }
        await run("2026-10-13T07:05:00+08:00", loader: TableLoader())  // offline just after waking
        #expect(ScheduledSync.lastOutcome(defaults: defaults.defaults)?.failure?.contains("cannotFindHost") == true)
        #expect(defaults.defaults.object(forKey: ScheduledSync.lastCheckKey) as? Date == before)  // still due
        await run("2026-10-13T07:20:00+08:00", loader: TableLoader([PageSync.defaultCalendarURL: ics]))
        #expect(await service.pushed.count == 1)
        #expect(ScheduledSync.lastOutcome(defaults: defaults.defaults)?.failure == nil)

        // Three failures in a row: it waits for the next time.
        try PageSettings(pages: [1: .month, 2: .photo, 3: .photo, 4: .photo], schedule: ["07:00", "17:00"])
            .save(to: defaults.defaults)
        for iso in ["2026-10-13T17:05:00+08:00", "2026-10-13T17:20:00+08:00", "2026-10-13T17:35:00+08:00"] {
            #expect(ScheduledSync.isDue(["07:00", "17:00"],
                                        lastCheck: defaults.defaults.object(forKey: ScheduledSync.lastCheckKey) as? Date,
                                        now: at(iso), calendar: calendar))
            await run(iso, loader: TableLoader())
        }
        #expect(defaults.defaults.object(forKey: ScheduledSync.lastCheckKey) as? Date == at("2026-10-13T17:35:00+08:00"))
        #expect(await service.pushed.count == 1)
    }
}
