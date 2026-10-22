import ShotsKit
import SwiftUI

/// The main window's own state, owned by the app so its menu commands can reach it directly.
/// (A focused value didn't work: it never reached the menus while the search field had focus,
/// so ⌘K was disabled and the keystroke fell through to the text field.)
@MainActor @Observable
final class MainWindowState {
    var showsInspector = true
    var showsPalette = false
    /// Bumped by ⌘F; the window moves focus to the search field when it changes.
    var searchFocusRequests = 0
}

/// Keyboard shortcuts in the app's menus: Find (⌘F), the command palette (⌘K), the inspector
/// (⌥⌘I), and ⌘1–⌘9 for the sidebar rows in order.
struct ShotsCommands: Commands {
    let model: AppModel
    let window: MainWindowState

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find") { window.searchFocusRequests += 1 }
                .keyboardShortcut("f")
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { window.showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }

        CommandMenu("Go") {
            Button("Command Palette…") { window.showsPalette.toggle() }
                .keyboardShortcut("k")
            Divider()
            ForEach(Array(scopes.prefix(9).enumerated()), id: \.offset) { index, scope in
                Button(scope.title) { model.scope = scope }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }

    /// The sidebar's rows, top to bottom: All, Needs Review, Failed, then the categories that
    /// hold screenshots (the ones folded under More aren't numbered).
    private var scopes: [SidebarScope] {
        let filled = model.categories.filter { model.counts.count(for: .category($0)) > 0 }
        return [.all, .review, .failed] + filled.map { .category($0) }
    }
}
