import AppKit
import Foundation

/// Keeps the app running while it talks to the calendar. `begin` and `end` come in pairs:
/// the view model calls `end` when the job is over, also after an error.
@MainActor
public protocol KeepAwake: AnyObject {
    func begin()
    func end()
}

/// Keeps App Nap and idle sleep away while a job runs (a push takes about two minutes).
@MainActor
public final class SystemKeepAwake: KeepAwake {
    /// Nested begin/end pairs: only the outermost pair acts.
    private var depth = 0
    private var activity: (any NSObjectProtocol)?

    public init() {}

    public func begin() {
        depth += 1
        guard depth == 1 else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Sending photos to the device")
    }

    public func end() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }
}

extension PushViewModel {
    /// For `NSApplicationDelegate.applicationShouldTerminate`: quitting during a push
    /// interrupts it, so ask first (Python: App.close). `ask` gets the texts in the current
    /// language and returns true to quit anyway.
    /// `keepSending` runs, before the reply is returned, when the user keeps the push: the
    /// app reopens its window there, since closing its only window is what quits it and
    /// that window is gone by now (Python asks before the window closes).
    public func confirmQuit(ask: @MainActor (Strings) -> Bool = askToQuitWhilePushing,
                            keepSending: @MainActor () -> Void = {}) -> NSApplication.TerminateReply {
        guard isPushing else { return .terminateNow }
        if ask(strings) { return .terminateNow }
        keepSending()
        return .terminateCancel
    }
}

/// The "仍在傳送" alert in the language of `strings`; true when the user chooses to quit anyway.
@MainActor @usableFromInline
func askToQuitWhilePushing(_ strings: Strings) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = strings[.quitWhilePushingTitle]
    alert.informativeText = strings[.quitWhilePushingMessage]
    alert.addButton(withTitle: strings[.keepSending])  // the default: nothing is lost
    alert.addButton(withTitle: strings[.quitAnyway]).hasDestructiveAction = true
    return alert.runModal() == .alertSecondButtonReturn
}
