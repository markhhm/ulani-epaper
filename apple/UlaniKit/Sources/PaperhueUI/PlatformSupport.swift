import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Keeps the app running while it talks to the calendar. `begin` and `end` come in pairs:
/// the view model calls `end` when the job is over, also after an error.
@MainActor
public protocol KeepAwake: AnyObject {
    func begin()
    func end()
}

/// The platform's way to keep a push alive.
///
/// iOS: a push takes ~2 minutes, longer than Auto-Lock (30 s in Low Power Mode), and a
/// locked screen suspends the app and stops the upload. So the idle timer
/// is off while a job runs, and the job is wrapped in a background task for the moments
/// the user switches apps. macOS: an activity keeps App Nap and idle sleep away.
@MainActor
public final class SystemKeepAwake: KeepAwake {
    /// Nested begin/end pairs: only the outermost pair acts.
    private var depth = 0
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #elseif os(macOS)
    private var activity: (any NSObjectProtocol)?
    #endif

    public init() {}

    public func begin() {
        depth += 1
        guard depth == 1 else { return }
        #if os(iOS)
        let application = UIApplication.shared
        application.isIdleTimerDisabled = true
        backgroundTask = application.beginBackgroundTask(withName: "Paperhue push") { [self] in
            // Called on the main thread when the system is about to suspend the app.
            MainActor.assumeIsolated { endBackgroundTask() }
        }
        #elseif os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Sending photos to the device")
        #endif
    }

    public func end() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
        #elseif os(macOS)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        #endif
    }

    #if os(iOS)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}

#if os(macOS)
extension PushViewModel {
    /// For `NSApplicationDelegate.applicationShouldTerminate`: quitting during a push
    /// interrupts it, so ask first (Python: App.close). `ask` returns true to quit anyway.
    /// `keepSending` runs, before the reply is returned, when the user keeps the push: the
    /// app reopens its window there, since closing its only window is what quits it and
    /// that window is gone by now (Python asks before the window closes).
    public func confirmQuit(ask: @MainActor () -> Bool = askToQuitWhilePushing,
                            keepSending: @MainActor () -> Void = {}) -> NSApplication.TerminateReply {
        guard isPushing else { return .terminateNow }
        if ask() { return .terminateNow }
        keepSending()
        return .terminateCancel
    }
}

/// The "仍在傳送" alert; true when the user chooses to quit anyway.
@MainActor @usableFromInline
func askToQuitWhilePushing() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = Strings.quitWhilePushingTitle
    alert.informativeText = Strings.quitWhilePushingMessage
    alert.addButton(withTitle: Strings.keepSending)  // the default: nothing is lost
    alert.addButton(withTitle: Strings.quitAnyway).hasDestructiveAction = true
    return alert.runModal() == .alertSecondButtonReturn
}
#endif
