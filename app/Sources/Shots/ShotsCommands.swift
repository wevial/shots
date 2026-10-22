import ShotsKit
import SwiftUI

/// What the main window lets the menu bar's commands do to it. The window publishes this with
/// `focusedSceneValue`, so the shortcuts work whenever that window is key.
struct WindowActions {
    var focusSearch: () -> Void
    var toggleInspector: () -> Void
    var openPalette: () -> Void
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

/// Keyboard shortcuts in the app's menus: Find (⌘F), the command palette (⌘K), the inspector
/// (⌥⌘I), and ⌘1–⌘9 for the sidebar rows in order.
struct ShotsCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowActions) private var actions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find") { actions?.focusSearch() }
                .keyboardShortcut("f")
                .disabled(actions == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { actions?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions == nil)
        }

        CommandMenu("Go") {
            Button("Command Palette…") { actions?.openPalette() }
                .keyboardShortcut("k")
                .disabled(actions == nil)
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
