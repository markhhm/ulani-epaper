import Foundation
import PaperhueAgenda
import PaperhuePages
import ServiceManagement
import UlaniKit

/// Runs the scheduled sync in the background: the app's own executable, started by launchd
/// every 15 minutes (and at login) with `--scheduled-sync` (Contents/Library/LaunchAgents).
public protocol BackgroundAgent: Sendable {
    func register() throws
    func unregister() throws
    /// Waiting for the user to allow it in System Settings › General › Login Items.
    var needsApproval: Bool { get }
}

/// What SyncAgent uses of SMAppService (a fake in tests).
protocol AgentService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: AgentService {}

/// The launch agent, through SMAppService.
public struct SyncAgent: BackgroundAgent {
    /// The plist in Contents/Library/LaunchAgents.
    public static let plistName = "io.github.markhhm.paperhue.sync.plist"

    private let service: @Sendable () -> any AgentService

    public init() {
        self.init(service: { SMAppService.agent(plistName: SyncAgent.plistName) })
    }

    init(service: @escaping @Sendable () -> any AgentService) {
        self.service = service
    }

    /// Registers it afresh when it is already registered: after an update launchd may refuse
    /// to start it, and only a new registration hands launchd the updated job
    /// (apple/DEVELOPING.md, "Scheduled sync after an update").
    public func register() throws {
        let service = service()
        if service.status == .enabled { try service.unregister() }
        try service.register()
    }

    public func unregister() throws {
        let service = service()
        if service.status != .notRegistered { try service.unregister() }
    }

    public var needsApproval: Bool { service().status == .requiresApproval }
}

/// The scheduled sync (Python: syncjob.py): when a daily time has passed since the last check,
/// read the calendars, draw the calendar pages and push them, like 立即同步. launchd starts it
/// every 15 minutes, so a time missed while the Mac slept or was off is made up once on the next
/// run after it wakes or logs in. A failed sync (just after waking, Wi-Fi or Bluetooth may not be
/// back yet) is tried again on the next runs, `maxAttempts` times in all.
public enum ScheduledSync {
    /// The launch agent's argument.
    public static let argument = "--scheduled-sync"
    static let lastCheckKey = "scheduledSyncLastCheck"
    static let attemptsKey = "scheduledSyncAttempts"
    static let outcomeKey = "lastSyncOutcome"
    /// When the agent last ran (its heartbeat), whatever it then did.
    static let lastRunKey = "scheduledSyncLastRun"
    /// When the app first looked for a heartbeat that was not there yet.
    static let watchingSinceKey = "scheduledSyncWatchingSince"
    /// When the app last registered the agent (啟用／更新排程 or a repair).
    static let lastRegisterKey = "scheduledSyncLastRegister"
    /// Tries per due time (Python: 3).
    static let maxAttempts = 3
    /// The agent counts as stuck after this long without running: two missed runs (launchd
    /// starts it every 15 minutes while the Mac is awake) and a margin. With the Mac awake,
    /// launchd has tried twice by then, so a new registration works; after a sleep it may not
    /// have, which costs one more round (apple/DEVELOPING.md).
    static let stuckAfter: TimeInterval = 35 * 60
    /// 每日排程 hints at 啟用／更新排程 after this long without a run.
    static let quietAfter: TimeInterval = 60 * 60

    /// How the last sync went (立即同步 or a scheduled one): no calendar content, only the time
    /// and a short message.
    public struct Outcome: Equatable, Sendable {
        public let at: Date
        /// nil when it succeeded; else the error's technical message (it never holds an address).
        public let failure: String?
    }

    /// Times count from now: a time already past today waits for tomorrow.
    static func startChecking(defaults: UserDefaults, now: Date) {
        defaults.set(now, forKey: lastCheckKey)
        defaults.removeObject(forKey: attemptsKey)
    }

    /// The latest daily time at or before `now` (today or yesterday), or nil without times.
    static func latest(_ times: [String], atOrBefore now: Date, calendar: Calendar) -> Date? {
        let minutes = times.compactMap(PageSettings.minutes).sorted(by: >)
        for days in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) else { continue }
            for minute in minutes {
                if let time = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day),
                   time <= now {
                    return time
                }
            }
        }
        return nil
    }

    /// A daily time has passed since `lastCheck`. Never checked: not yet (checking starts now).
    static func isDue(_ times: [String], lastCheck: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let lastCheck, let time = latest(times, atOrBefore: now, calendar: calendar) else { return false }
        return time > lastCheck
    }

    /// Keeps how a sync went (`failure`: its error, nil when it worked).
    static func record(defaults: UserDefaults, at: Date, failure: (any Error)?) {
        var kept: [String: Any] = ["at": at]
        if let failure { kept["failure"] = String(describing: failure) }
        defaults.set(kept, forKey: outcomeKey)
    }

    public static func lastOutcome(defaults: UserDefaults) -> Outcome? {
        guard let kept = defaults.dictionary(forKey: outcomeKey), let at = kept["at"] as? Date else { return nil }
        return Outcome(at: at, failure: kept["failure"] as? String)
    }

    /// When the agent last ran, if it ever did.
    static func lastRun(defaults: UserDefaults) -> Date? {
        defaults.object(forKey: lastRunKey) as? Date
    }

    /// How long the agent has not run: since its last run, else since the app started
    /// watching. Nil before either.
    static func quiet(defaults: UserDefaults, now: Date) -> TimeInterval? {
        guard let since = lastRun(defaults: defaults) ?? defaults.object(forKey: watchingSinceKey) as? Date else {
            return nil
        }
        return now.timeIntervalSince(since)
    }

    /// The app's check with a schedule on, at start and whenever it becomes active: true when
    /// the agent should be registered again. That is when it has not run for `stuckAfter`, and
    /// was not registered within `stuckAfter` either: a new registration restarts launchd's two
    /// tries, so registering at every check would never let them finish. Without any heartbeat
    /// yet (every install up to 0.4.0), the wait starts at the first check.
    static func isStuck(defaults: UserDefaults, now: Date) -> Bool {
        guard let quiet = quiet(defaults: defaults, now: now) else {
            defaults.set(now, forKey: watchingSinceKey)
            return false
        }
        guard quiet > stuckAfter else { return false }
        if let registered = defaults.object(forKey: lastRegisterKey) as? Date,
           now.timeIntervalSince(registered) <= stuckAfter {
            return false
        }
        return true
    }

    /// One run from launchd: notes the run (the heartbeat), then syncs when a time is due and
    /// keeps the outcome. The check moves on when nothing is due, after a sync that worked, or
    /// after the last try. Settings that cannot be read, or no times, do nothing more.
    public static func run(defaults: UserDefaults = .standard, sync: PageSync = .app,
                           service: any PushService = LivePushService(), calendar: Calendar = .current) async {
        defaults.set(sync.now(), forKey: lastRunKey)
        guard let settings = try? PageSettings.load(from: defaults), !settings.schedule.isEmpty else { return }
        let now = sync.now()
        let lastCheck = defaults.object(forKey: lastCheckKey) as? Date
        guard isDue(settings.schedule, lastCheck: lastCheck, now: now, calendar: calendar) else {
            defaults.set(now, forKey: lastCheckKey)
            return
        }
        do {
            _ = try await sync.sync(settings, push: { frames, progress in
                try await service.push(frames: frames, progress: progress ?? { _ in })
            })
            record(defaults: defaults, at: now, failure: nil)
            startChecking(defaults: defaults, now: now)
        } catch {
            record(defaults: defaults, at: now, failure: error)
            let attempts = defaults.integer(forKey: attemptsKey) + 1
            if attempts < maxAttempts {
                defaults.set(attempts, forKey: attemptsKey)  // the next run tries again
            } else {
                startChecking(defaults: defaults, now: now)
            }
        }
    }
}
