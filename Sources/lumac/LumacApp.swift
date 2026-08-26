import SwiftUI
import AppKit

@main
struct LumacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var app: AppState { .shared }

    var body: some Scene {
        Window("lumac", id: "main") {
            RootView()
                .environment(app)
        }
        .defaultSize(width: Metrics.windowWidth, height: Metrics.windowHeight)
        // The 52pt bar is drawn by the app, so the system title bar is hidden
        // and only the traffic lights remain.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let state = AppState.shared
            // The menu bar item is the one part of the app that must keep
            // working with every window closed, so it owns its own polling.
            state.startPolling()
            menuBar = MenuBarController(app: state)

            // When the main window closes (the red ✕), drop the Dock icon and
            // live only in the menu bar. Quitting is done from the HUD's 退出.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    guard (note.object as? NSWindow)?.identifier?.rawValue == "main" else { return }
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    /// Closing the window leaves the menu bar item running, which is the point
    /// of a resident monitor.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon (while regular) with no window open reopens it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppState.shared.openMainWindow() } }
        return true
    }
}
