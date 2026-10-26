import ShotsKit
import SwiftUI

/// The palette's sections. Each command calls one existing `AppModel` action.
@MainActor
extension PaletteSection {
    /// Actions on the selected screenshot, under its title.
    static func selection(_ shot: Shot, model: AppModel, window: MainWindowState) -> PaletteSection {
        if shot.isDeleted {
            return PaletteSection(id: "selection", title: shot.displayTitle, commands: [
                PaletteCommand(id: "restore", title: "Restore", systemImage: "arrow.uturn.backward") {
                    Task { await model.restore(shot) }
                },
                PaletteCommand(id: "quick-look", title: "Quick Look", systemImage: "eye", shortcut: "Space") { model.quickLook(shot) },
                PaletteCommand(id: "delete-now", title: "Delete Immediately", systemImage: "trash", shortcut: "⌘⌫") {
                    window.confirmingPermanentDelete = .shot(shot)
                },
            ])
        }
        var commands = [
            PaletteCommand(id: "copy-image", title: "Copy Image", systemImage: "doc.on.doc", shortcut: "⌘C") { model.copyImage(shot) },
            PaletteCommand(id: "edit", title: "Edit Image", systemImage: "crop", shortcut: "⌘E") { window.editingShot = shot },
            PaletteCommand(id: "copy-path", title: "Copy Path", systemImage: "link") { model.copyPath(shot) },
            PaletteCommand(id: "quick-look", title: "Quick Look", systemImage: "eye", shortcut: "Space") { model.quickLook(shot) },
            PaletteCommand(id: "reveal", title: "Reveal in Finder", systemImage: "folder") { model.revealInFinder(shot) },
            PaletteCommand(id: "open", title: "Open", systemImage: "arrow.up.forward.app") { model.open(shot) },
            PaletteCommand(id: "duplicate", title: "Duplicate", systemImage: "plus.square.on.square", shortcut: "⌘D") {
                Task { await model.duplicate(shot) }
            },
            PaletteCommand(id: "delete", title: "Delete", systemImage: "trash", shortcut: "⌘⌫") {
                Task { await model.delete(shot) }
            },
        ]

        if shot.isScratch {
            commands.append(PaletteCommand(id: "keep", title: "Keep", systemImage: "checkmark.circle", tint: .purple) {
                Task { await model.keep(shot) }
            })
        }

        if shot.needsReview, let suggestion = shot.suggestedCategory {
            commands.append(PaletteCommand(
                id: "accept", title: "Accept Suggestion: \(suggestion)", systemImage: "checkmark.circle", tint: .orange
            ) { Task { await model.recategorize(shot, to: suggestion) } })
        }

        for category in model.categories where category != shot.category {
            commands.append(PaletteCommand(
                id: "move.\(category)", title: "Move to \(category)",
                systemImage: SidebarView.categorySymbol(category), tint: Theme.color(for: category)
            ) { Task { await model.recategorize(shot, to: category) } })
        }

        for backend in ClassifierBackend.rerunnable {
            commands.append(PaletteCommand(
                id: "rerun.\(backend.id)", title: "Re-run with \(backend.displayName)", systemImage: "arrow.clockwise"
            ) { Task { await model.rerun(shot, backend: backend) } })
        }

        return PaletteSection(id: "selection", title: shot.displayTitle, commands: commands)
    }

    /// Every sidebar scope.
    static func goTo(model: AppModel) -> PaletteSection {
        let scopes: [SidebarScope] = [.all, .review, .failed, .cleanup] + model.categories.map { .category($0) } + [.deleted]
        let commands = scopes.map { scope in
            let (symbol, tint): (String, Color?) = switch scope {
            case .category(let name): (SidebarView.categorySymbol(name), Theme.color(for: name))
            case .review: (scope.systemImage, .orange)
            case .failed: (scope.systemImage, .red)
            case .cleanup: (scope.systemImage, .purple)
            case .all, .deleted: (scope.systemImage, nil)
            }
            return PaletteCommand(id: "go.\(scope.title)", title: scope.title, systemImage: symbol, tint: tint) {
                model.scope = scope
            }
        }
        return PaletteSection(id: "go", title: "Go to", commands: commands)
    }

    static func app(
        model: AppModel,
        showsInspector: Binding<Bool>,
        showsCapturePreview: Binding<Bool>,
        openStatusWindow: @escaping () -> Void
    ) -> PaletteSection {
        let paused = model.daemon.isPaused
        return PaletteSection(id: "app", title: "App", commands: [
            PaletteCommand(
                id: "inspector", title: showsInspector.wrappedValue ? "Hide Inspector" : "Show Inspector",
                systemImage: "sidebar.trailing", shortcut: "⌥⌘I"
            ) { showsInspector.wrappedValue.toggle() },
            PaletteCommand(
                id: "pause", title: paused ? "Resume Watching" : "Pause Watching",
                systemImage: paused ? "play.circle" : "pause.circle"
            ) { Task { await model.togglePaused() } },
            PaletteCommand(id: "refresh", title: "Refresh", systemImage: "arrow.triangle.2.circlepath", shortcut: "⌘R") {
                Task { await model.refresh() }
            },
            PaletteCommand(id: "inbox", title: "Open Inbox Folder", systemImage: "tray.and.arrow.down") { model.openInbox() },
            PaletteCommand(id: "status", title: "Status & Permissions", systemImage: "checkmark.shield", shortcut: "⌘,") {
                openStatusWindow()
            },
            PaletteCommand(
                id: "capture-preview",
                title: showsCapturePreview.wrappedValue ? "Hide Preview After Capture" : "Show Preview After Capture",
                systemImage: "rectangle.inset.bottomtrailing.filled"
            ) { showsCapturePreview.wrappedValue.toggle() },
        ])
    }

    /// Full-text matches from every scope. Choosing one shows it under All Screenshots.
    static func screenshots(_ shots: [Shot], model: AppModel) -> PaletteSection {
        PaletteSection(id: "screenshots", title: "Screenshots", commands: shots.map { shot in
            PaletteCommand(
                id: "shot.\(shot.id)", title: shot.displayTitle, systemImage: "photo",
                screenshot: (shot.fileURL, shot.category)
            ) { model.show(shot) }
        })
    }
}
