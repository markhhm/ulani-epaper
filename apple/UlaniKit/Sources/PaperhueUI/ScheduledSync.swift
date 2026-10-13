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

/// The launch agent, through SMAppService.
public struct SyncAgent: BackgroundAgent {
    /// The plist in Contents/Library/LaunchAgents.
    public static let plistName = "io.github.markhhm.paperhue.sync.plist"

    public init() {}

    private var service: SMAppService { .agent(plistName: Self.plistName) }

    public func register() throws {
        if service.status != .enabled { try service.register() }
    }

    public func unregister() throws {
        if service.status != .notRegistered { try service.unregister() }
    }

    public var needsApproval: Bool { service.status == .requiresApproval }
}

/// The scheduled sync (Python: syncjob.py): when a daily time has passed since the last check,
/// read the calendars, draw the calendar pages and push them, like 立即同步. launchd starts it
/// every 15 minutes, so a time missed while the Mac slept or was off is made up once on the next
/// run after it wakes or logs in.
public enum ScheduledSync {
    /// The launch agent's argument.
    public static let argument = "--scheduled-sync"
    static let lastCheckKey = "scheduledSyncLastCheck"
    static let outcomeKey = "scheduledSyncOutcome"

    /// How the last scheduled sync went: no calendar content, only the time and a short message.
    public struct Outcome: Equatable, Sendable {
        public let at: Date
        /// nil when it succeeded; else the error's technical message (it never holds an address).
        public let failure: String?
    }

    /// Times count from now: a time already past today waits for tomorrow.
    static func startChecking(defaults: UserDefaults, now: Date) {
        defaults.set(now, forKey: lastCheckKey)
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

    public static func lastOutcome(defaults: UserDefaults) -> Outcome? {
        guard let kept = defaults.dictionary(forKey: outcomeKey), let at = kept["at"] as? Date else { return nil }
        return Outcome(at: at, failure: kept["failure"] as? String)
    }

    /// One run from launchd: syncs when a time is due and keeps the outcome. Settings that
    /// cannot be read, or no times, do nothing.
    public static func run(defaults: UserDefaults = .standard, sync: PageSync = .app,
                           service: any PushService = LivePushService(), calendar: Calendar = .current) async {
        guard let settings = try? PageSettings.load(from: defaults), !settings.schedule.isEmpty else { return }
        let now = sync.now()
        let lastCheck = defaults.object(forKey: lastCheckKey) as? Date
        defaults.set(now, forKey: lastCheckKey)
        guard isDue(settings.schedule, lastCheck: lastCheck, now: now, calendar: calendar) else { return }
        var outcome: [String: Any] = ["at": now]
        do {
            _ = try await sync.sync(settings, push: { frames, progress in
                try await service.push(frames: frames, progress: progress ?? { _ in })
            })
        } catch {
            outcome["failure"] = String(describing: error)
        }
        defaults.set(outcome, forKey: outcomeKey)
    }
}
