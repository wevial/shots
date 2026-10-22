import AppKit
import ShotsKit
import SwiftUI

/// The menu bar menu: Open Shots, Needs Review, recent shots, Open Inbox Folder, Quit.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Shots") { openMainWindow() }

        Button("Needs Review (\(model.counts.review))") {
            model.show(.review)
            openMainWindow()
        }

        Divider()

        if model.recentShots.isEmpty {
            Text("No screenshots yet")
        } else {
            Section("Recent") {
                ForEach(model.recentShots) { shot in
                    Button(shot.displayTitle) {
                        model.show(shot)
                        openMainWindow()
                    }
                }
            }
        }

        Divider()

        Button("Open Inbox Folder") { model.openInbox() }

        Button("Quit Shots") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// A menu bar app isn't frontmost, so the window must be opened and the app activated.
    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// The status item itself: the icon, plus the review count when there is one.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let review = model.counts.review
        if review > 0 {
            Label("\(review)", systemImage: "photo.stack")
                .labelStyle(.titleAndIcon) // Menu bar labels default to icon only.
        } else {
            Image(systemName: "photo.stack")
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
