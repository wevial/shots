import ShotsCore
import ShotsKit
import SwiftUI

@main
struct ShotsApp: App {
    // One model for the whole app, shared by the windows and the menu bar.
    @State private var model: AppModel
    @State private var mainWindow = MainWindowState()
    /// Kept for the app's lifetime; it shows its own panels.
    @State private var capturePreviews: CapturePreviewController
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        let model = AppModel()
        // Start here rather than in a view's .task: the watcher and the menu bar badge must
        // run while no window is open.
        model.start()
        ActivationPolicy.shared.start()
        let capturePreviews = CapturePreviewController(model: model)
        capturePreviews.start()
        AppDelegate.beforeQuit = { await model.daemon.shutdown() }
        _model = State(initialValue: model)
        _capturePreviews = State(initialValue: capturePreviews)
    }

    var body: some Scene {
        // Suppressed at launch so starting at login doesn't pop a window; the first launch
        // opens it from the menu bar label instead.
        Window("Shots", id: "main") {
            ContentView()
                .environment(model)
                .environment(mainWindow)
        }
        .defaultSize(width: 1200, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
            StatusCommand()
            ShotsCommands(model: model, window: mainWindow)
        }

        Window("Shots Status", id: "status") {
            StatusView()
                .environment(model)
        }
        .defaultSize(width: 540, height: 680)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
    }
}

/// Shots ▸ Status & Permissions… (⌘,), where macOS apps keep Settings. The menu bar item
/// opens the same window, but macOS can hide that item, so this is the reliable way in.
struct StatusCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Status & Permissions…") {
                ActivationPolicy.shared.activateForWindow()
                openWindow(id: "status")
            }
            .keyboardShortcut(",")
        }
    }
}

/// Lets a job that is mid-way through filing finish before the app exits, as the old
/// daemon did on SIGTERM. Jobs that haven't started stay pending for the next launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var beforeQuit: (@MainActor @Sendable () async -> Void)?
    /// Set by the menu bar label, which has SwiftUI's openWindow; the delegate doesn't.
    static var openMainWindow: (@MainActor () -> Void)?
    /// True when macOS started us as a login item: stay in the menu bar, open no window.
    private(set) static var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        Self.launchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Double-clicking the app (or clicking it in Spotlight) while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // `hasVisibleWindows` counts a capture preview, which shouldn't stop the window opening.
        let windowOpen = sender.windows.contains { $0.isVisible && ActivationPolicy.isContentWindow($0) }
        if !windowOpen { Self.openMainWindow?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let beforeQuit = Self.beforeQuit else { return .terminateNow }
        Self.beforeQuit = nil
        Task {
            // A classifier can take up to its timeout; don't hold up logout for longer than 10 s.
            _ = await withDeadline(.seconds(10)) { await beforeQuit() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
