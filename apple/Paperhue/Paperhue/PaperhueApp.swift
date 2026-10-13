import SwiftUI
import PaperhueUI

/// Started by launchd with `--scheduled-sync` (the daily sync's launch agent), the executable
/// runs one scheduled sync without any window and exits; otherwise it is the app.
@main @MainActor
enum Main {
    static func main() {
        guard CommandLine.arguments.contains(ScheduledSync.argument) else {
            PaperhueApp.main()
            return
        }
        Task {
            await ScheduledSync.run()
            exit(0)
        }
        dispatchMain()
    }
}

/// The app shell: everything else lives in PaperhueUI (Swift package, tested with
/// `swift test`). Every window shows `PushViewModel.shared`, so the device does one job
/// at a time however many windows are open.
struct PaperhueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window, like the Windows app. SwiftUI quits the app when its only Window
        // closes, so closing it goes through applicationShouldTerminate as well. The window
        // shows the title in the current language (RootView); this one names it in the
        // Window menu, in the language of the rest of the menu bar (the launch language).
        Window(Strings(PushViewModel.shared.menuLanguage)[.appTitle], id: AppDelegate.mainWindow) {
            RootView()
                .background { MainWindowOpener(delegate: appDelegate) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindow = "main"

    /// Opens the main window, or brings it to the front. Set by the window's content:
    /// `openWindow` is only available in a view's environment.
    var openMainWindow: (@MainActor () -> Void)?

    /// Quitting during a push interrupts it: ask 「仍在傳送」 first, in the current language
    /// (Python: App.close).
    /// When the window's close button or Cmd-W asked, the window is already gone, so
    /// keeping the push reopens it, with its progress (the model outlives the window).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        PushViewModel.shared.confirmQuit(keepSending: { [weak self] in
            // After the reply: the app is still deciding whether to terminate.
            Task { @MainActor in self?.openMainWindow?() }
        })
    }
}

/// Hands the main window's `openWindow` action to the app delegate.
private struct MainWindowOpener: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            delegate.openMainWindow = { [openWindow] in openWindow(id: AppDelegate.mainWindow) }
        }
    }
}
