import Foundation
import PaperhueAgenda
import PaperhuePages
import ServiceManagement
import Testing
@testable import PaperhueUI

// After an ad hoc build replaces the app, launchd refuses to start the launch agent until it is
// registered again, and that only works once launchd has tried twice (apple/DEVELOPING.md,
// "Scheduled sync after an update"). The app registers it again when it has stopped running.

/// A clock the test moves.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Date

    init(_ now: Date) { time = now }

    var now: Date { lock.withLock { time } }

    func advance(minutes: Double) { lock.withLock { time += minutes * 60 } }
}

@MainActor
@Suite final class ScheduleRepairTests {
    let defaults = TestDefaults()
    let agent = FakeAgent()
    let clock = TestClock(OffsetDateTime(iso: "2026-10-15T12:00:00+08:00")!.instant)
    let folder: URL

    init() throws {
        folder = try temporaryDirectory()
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func makeModel(schedule: [String] = ["07:30", "17:00"]) throws -> PushViewModel {
        try PageSettings(schedule: schedule).save(to: defaults.defaults)
        let clock = clock
        let sync = PageSync(notes: NoteStore(url: folder.appendingPathComponent("notes.json")),
                            secrets: MemoryFeedSecrets(), loader: TableLoader(), now: { clock.now })
        return PushViewModel(service: FakePushService(), keepAwake: FakeKeepAwake(), defaults: defaults.defaults,
                             preferredLanguages: ["zh-Hant-TW"], pageSync: sync, agent: agent)
    }

    /// The agent ran `minutes` ago.
    func ran(minutesAgo minutes: Double) {
        defaults.defaults.set(clock.now - minutes * 60, forKey: ScheduledSync.lastRunKey)
    }

    @Test func aFreshHeartbeatLeavesTheAgentAlone() throws {
        let model = try makeModel()
        ran(minutesAgo: 10)
        model.repairScheduleIfStuck()
        clock.advance(minutes: 20)  // 30 minutes: launchd may not have tried twice yet
        model.repairScheduleIfStuck()
        #expect(agent.log.isEmpty)
    }

    @Test func aStaleHeartbeatRegistersTheAgentOnceThenWaits() throws {
        let model = try makeModel()
        ran(minutesAgo: 36)
        model.repairScheduleIfStuck()
        #expect(agent.log == ["register"])
        // Opening the app again soon must not restart launchd's two tries.
        clock.advance(minutes: 1)
        model.repairScheduleIfStuck()
        clock.advance(minutes: 33)
        model.repairScheduleIfStuck()
        #expect(agent.log == ["register"])
        // Still not running 35 minutes after that try: once more.
        clock.advance(minutes: 2)
        model.repairScheduleIfStuck()
        #expect(agent.log == ["register", "register"])
    }

    @Test func noHeartbeatYetWaitsFrom35MinutesAfterTheFirstCheck() throws {
        // Every install up to 0.4.0: the agent never wrote one.
        let model = try makeModel()
        model.repairScheduleIfStuck()
        clock.advance(minutes: 34)
        model.repairScheduleIfStuck()
        #expect(agent.log.isEmpty)
        clock.advance(minutes: 2)
        model.repairScheduleIfStuck()
        #expect(agent.log == ["register"])
    }

    @Test func aRunAfterTheFirstCheckCountsFromTheRun() throws {
        let model = try makeModel()
        model.repairScheduleIfStuck()  // watching from now
        clock.advance(minutes: 30)
        ran(minutesAgo: 0)
        clock.advance(minutes: 20)
        model.repairScheduleIfStuck()
        #expect(agent.log.isEmpty)
    }

    @Test func withTheScheduleOffNothingIsRegistered() throws {
        let model = try makeModel(schedule: [])
        ran(minutesAgo: 600)
        model.repairScheduleIfStuck()
        #expect(agent.log.isEmpty)
        #expect(!model.scheduleLooksStuck)
    }

    @Test func anAgentWaitingForApprovalIsLeftToTheApprovalHint() throws {
        let model = try makeModel()
        agent.needsApproval = true
        ran(minutesAgo: 600)
        model.repairScheduleIfStuck()
        #expect(agent.log.isEmpty && !model.scheduleLooksStuck && model.scheduleNeedsApproval)
    }

    @Test func aFailedRegistrationIsTriedAgainAtTheNextCheckAndShowsTheHint() throws {
        let model = try makeModel()
        agent.failure = URLError(.unknown)
        ran(minutesAgo: 36)
        model.repairScheduleIfStuck()
        #expect(agent.log == ["register"] && model.scheduleLooksStuck == false)  // quiet 36 min: no hint yet
        ran(minutesAgo: 61)
        #expect(model.scheduleLooksStuck)
        clock.advance(minutes: 1)
        model.repairScheduleIfStuck()
        #expect(agent.log == ["register", "register"])
        agent.failure = nil
        model.repairScheduleIfStuck()
        #expect(agent.log == ["register", "register", "register"] && !model.scheduleLooksStuck)
        model.repairScheduleIfStuck()
        #expect(agent.log.count == 3)  // worked: waits again
    }

    @Test func turningTheScheduleOnCountsAsATry() throws {
        let model = try makeModel()
        ran(minutesAgo: 600)
        #expect(model.scheduleLooksStuck)
        #expect(model.setSchedule(["07:30", "17:00"]) == nil)  // 啟用／更新排程, times unchanged
        model.repairScheduleIfStuck()
        #expect(agent.log == ["register"])
        #expect(!model.scheduleLooksStuck)  // the hint asked for just that
        clock.advance(minutes: 36)
        #expect(model.scheduleLooksStuck)  // and it still has not run
    }

    @Test func theDialogSaysWhenTheScheduleLastRanAndHintsWhenItStopped() throws {
        let model = try makeModel()
        #expect(model.scheduleLastRun == nil && !model.scheduleLooksStuck)
        #expect(model.strings.scheduleLastRun(nil) == "排程上次執行：尚無紀錄")
        ran(minutesAgo: 59)
        #expect(model.scheduleLastRun == clock.now - 59 * 60 && !model.scheduleLooksStuck)
        ran(minutesAgo: 61)
        #expect(model.scheduleLooksStuck)
        #expect(model.strings[.scheduleStuck].contains("「啟用／更新排程」"))

        // Never ran: an hour after the app started watching.
        defaults.defaults.removeObject(forKey: ScheduledSync.lastRunKey)
        model.repairScheduleIfStuck()
        #expect(!model.scheduleLooksStuck)
        clock.advance(minutes: 61)
        #expect(model.scheduleLooksStuck)
    }

    @Test func theLastRunIsShownInTheMacsTime() throws {
        let model = try makeModel()
        let at = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 7, minute: 5))!
        #expect(model.strings.scheduleLastRun(at) == "排程上次執行：10/15 07:05")
        model.setLanguage(.english)
        #expect(model.strings.scheduleLastRun(at) == "Schedule last ran: 10/15 07:05")
        #expect(model.strings.scheduleLastRun(nil) == "Schedule last ran: none yet")
    }
}

@Suite struct ScheduledSyncHeartbeatTests {
    @Test(arguments: [false, true])
    func everyRunWritesTheHeartbeatFirst(readable: Bool) async throws {
        let defaults = TestDefaults()
        if readable {
            try PageSettings(schedule: []).save(to: defaults.defaults)  // no times: nothing to do
        } else {
            defaults.defaults.set(Data("{".utf8), forKey: PageSettings.defaultsKey)
        }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = OffsetDateTime(iso: "2026-10-15T12:00:00+08:00")!.instant
        let sync = PageSync(notes: NoteStore(url: folder.appendingPathComponent("notes.json")),
                            secrets: MemoryFeedSecrets(), loader: TableLoader(), now: { now })
        await ScheduledSync.run(defaults: defaults.defaults, sync: sync, service: FakePushService())
        #expect(ScheduledSync.lastRun(defaults: defaults.defaults) == now)
    }
}

/// SMAppService as SyncAgent sees it.
final class FakeAppService: AgentService, @unchecked Sendable {
    var status: SMAppService.Status
    private(set) var log: [String] = []

    init(_ status: SMAppService.Status) { self.status = status }

    func register() throws {
        log.append("register")
        status = .enabled
    }

    func unregister() throws {
        log.append("unregister")
        status = .notRegistered
    }
}

@Suite struct SyncAgentTests {
    @Test func registeringAnEnabledAgentRegistersItAfresh() throws {
        // launchd keeps refusing a job whose record still names the old build until it is
        // submitted again; register() alone leaves the job as it is.
        let enabled = FakeAppService(.enabled)
        try SyncAgent(service: { enabled }).register()
        #expect(enabled.log == ["unregister", "register"])

        for status in [SMAppService.Status.notRegistered, .requiresApproval] {
            let service = FakeAppService(status)
            try SyncAgent(service: { service }).register()
            #expect(service.log == ["register"])
        }
    }
}
