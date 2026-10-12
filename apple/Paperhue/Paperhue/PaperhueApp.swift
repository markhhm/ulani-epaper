import SwiftUI
import PaperhueUI

/// The app shell: everything else lives in PaperhueUI (Swift package, tested with
/// `swift test`). Every window shows `PushViewModel.shared`, so the calendar does one job
/// at a time however many windows are open.
@main
struct PaperhueApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        // One window, like the Windows app. SwiftUI quits the app when its only Window
        // closes, so closing it goes through applicationShouldTerminate as well.
        Window(Strings.appTitle, id: AppDelegate.mainWindow) {
            RootView()
                .background { MainWindowOpener(delegate: appDelegate) }
        }
        #else
        WindowGroup {
            RootView()
        }
        #endif
    }
}

#if os(macOS)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindow = "main"

    /// Opens the main window, or brings it to the front. Set by the window's content:
    /// `openWindow` is only available in a view's environment.
    var openMainWindow: (@MainActor () -> Void)?

    /// Quitting during a push interrupts it: ask 「仍在傳送」 first (Python: App.close).
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
#endif
