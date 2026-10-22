import AppKit
import ShotsKit
import SwiftUI

/// The menu bar menu: status, pause, Open Shots, Needs Review, recent shots, settings, Quit.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(CapturePreviewController.enabledKey) private var showsCapturePreview = true

    var body: some View {
        Text(model.statusLine)
        if let last = model.lastFiledLine {
            Text(last)
        }

        Button(model.daemon.isPaused ? "Resume Watching" : "Pause Watching") {
            Task { await model.togglePaused() }
        }

        Divider()

        Button("Open Shots") { open("main") }

        Button("Needs Review (\(model.counts.review))") {
            model.show(.review)
            open("main")
        }

        Divider()

        if model.recentShots.isEmpty {
            Text("No screenshots yet")
        } else {
            Section("Recent") {
                ForEach(model.recentShots) { shot in
                    Button(shot.displayTitle) {
                        model.show(shot)
                        open("main")
                    }
                }
            }
        }

        Divider()

        Button("Open Inbox Folder") { model.openInbox() }

        Toggle("Show Preview After Capture", isOn: $showsCapturePreview)

        Toggle("Launch at Login", isOn: Binding(
            get: { model.loginItem.isOn },
            set: { model.loginItem.setOn($0) }
        ))

        Button("Status & Permissions…") { open("status") }

        Button("Quit Shots") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// A menu bar app isn't frontmost, so the window must be opened and the app activated.
    private func open(_ id: String) {
        ActivationPolicy.shared.activateForWindow()
        openWindow(id: id)
    }
}

/// The status item itself: the icon, plus the review count when there is one.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let review = model.counts.review
        Group {
            if model.daemon.isPaused {
                Image(systemName: "pause.circle")
            } else if review > 0 {
                Label("\(review)", systemImage: "photo.stack")
                    .labelStyle(.titleAndIcon) // Menu bar labels default to icon only.
            } else {
                Image(systemName: "photo.stack")
            }
        }
        .task {
            let openWindow = openWindow
            let open: @MainActor () -> Void = {
                ActivationPolicy.shared.activateForWindow()
                openWindow(id: "main")
            }
            AppDelegate.openMainWindow = open
            // A normal launch shows the window; a login-item launch stays in the menu bar,
            // except before the Launch at Login offer has been answered (it lives in the window).
            if !AppDelegate.launchedAsLoginItem || !model.loginItem.wasOffered { open() }
        }
    }
}

#Preview {
    MenuBarContent()
        .environment(AppModel.preview())
        .frame(width: 260)
}

#Preview("Label") {
    MenuBarLabel()
        .environment(AppModel.preview())
        .padding()
}
