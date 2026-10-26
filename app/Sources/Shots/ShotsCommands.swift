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
    /// The shot open in the image editor sheet.
    var editingShot: Shot?
    /// Mirrors the search field's focus, so ⌘⌫ deletes text there instead of the selected shot.
    var searchHasFocus = false
    /// What "Delete Immediately" is waiting on the user to confirm.
    var confirmingPermanentDelete: PermanentDelete?

    enum PermanentDelete {
        case shot(Shot)
        /// Everything in Recently Deleted.
        case all
    }

    /// Whether menu shortcuts that act on the selected shot should take keys: not while
    /// typing (search, palette) or editing.
    var acceptsShotShortcuts: Bool { !searchHasFocus && !showsPalette && editingShot == nil }
}

/// Keyboard shortcuts in the app's menus: Duplicate (⌘D) and Delete (⌘⌫), Find (⌘F),
/// Edit Image (⌘E), the command palette (⌘K), the inspector (⌥⌘I), and ⌘1–⌘9 for the sidebar
/// rows in order.
struct ShotsCommands: Commands {
    let model: AppModel
    let window: MainWindowState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            let shot = window.acceptsShotShortcuts ? model.selectedShot : nil
            if let shot, shot.isDeleted {
                Button("Restore") { Task { await model.restore(shot) } }
                Button("Delete Immediately…") { window.confirmingPermanentDelete = .shot(shot) }
                    .keyboardShortcut(.delete)
            } else {
                Button("Duplicate") { if let shot { Task { await model.duplicate(shot) } } }
                    .keyboardShortcut("d")
                    .disabled(shot?.fileExists != true)
                Button("Delete") { if let shot { Task { await model.delete(shot) } } }
                    .keyboardShortcut(.delete)
                    .disabled(shot == nil)
            }
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find") { window.searchFocusRequests += 1 }
                .keyboardShortcut("f")
            Button("Edit Image…") { window.editingShot = model.selectedShot }
                .keyboardShortcut("e")
                .disabled(model.selectedShot.map { !$0.fileExists || $0.isDeleted } ?? true)
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

    /// The sidebar's rows, top to bottom: All, Needs Review, Failed, Clean Up, then the categories that
    /// hold screenshots (the ones folded under More aren't numbered).
    private var scopes: [SidebarScope] {
        let filled = model.categories.filter { model.counts.count(for: .category($0)) > 0 }
        return [.all, .review, .failed, .cleanup] + filled.map { .category($0) }
    }
}
