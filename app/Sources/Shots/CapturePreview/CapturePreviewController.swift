import AppKit
import ShotsCore
import ShotsKit
import SwiftUI

/// Shows a floating panel in the bottom-right corner for each screenshot that lands, in place
/// of the system's thumbnail: "Copied" and "Filing…" first, then the title, category and Open
/// (or a failure). Up to three stack up, newest at the bottom.
@MainActor
final class CapturePreviewController {
    /// The UserDefaults key behind "Show Preview After Capture". Missing means on.
    static let enabledKey = "showPreviewAfterCapture"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static let maxVisible = 3
    private static let hideDelay: Duration = .seconds(5)
    /// A preview stuck on "Filing…" this long (a hung classifier) goes away anyway.
    private static let filingTimeout: Duration = .seconds(180)
    /// From the edge of the screen to the panel, which adds `CapturePreviewPanel.margin` itself.
    private static let screenInset: CGFloat = 8

    private let model: AppModel
    /// Oldest first; the newest sits at the bottom of the screen.
    private var previews: [CapturePreview] = []
    private var panels: [CapturePreview.ID: CapturePreviewPanel] = [:]
    private var hideTasks: [CapturePreview.ID: Task<Void, Never>] = [:]
    /// Where the pointer was when the stack's first panel appeared; the rest join it there.
    private var screen: NSScreen?
    private var openMenus = 0
    private var listener: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard listener == nil else { return }
        let events = model.daemon.captureEvents()
        listener = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        // While the category menu is open the pointer is outside the panel, and the panel
        // must not hide under it. (Any menu in the app counts; that's harmless.)
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openMenus += 1 }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openMenus = max(0, (self?.openMenus ?? 1) - 1) }
        }
    }

    // MARK: Events

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .landed(let jobID, let path, let copied):
            guard Self.isEnabled else { return }
            show(CapturePreview(id: jobID, inboxPath: path, copied: copied))
        case .filed(let jobID, let row):
            guard let preview = preview(jobID) else { return }
            preview.phase = .filed(Shot(row: row))
            scheduleHide(preview)
        case .failed(let jobID, let error):
            guard let preview = preview(jobID) else { return }
            preview.phase = .failed(error)
            scheduleHide(preview)
        }
    }

    private func preview(_ jobID: Int64) -> CapturePreview? {
        previews.first { $0.id == jobID }
    }

    // MARK: Actions from the card

    private func open(_ preview: CapturePreview) {
        switch preview.phase {
        case .filing: return
        case .filed(let shot): model.show(shot)
        case .failed: model.show(.failed)
        }
        AppDelegate.openMainWindow?()
        dismiss(preview)
    }

    private func recategorize(_ preview: CapturePreview, to category: String) {
        guard let shot = preview.shot else { return }
        Task {
            if let moved = await model.recategorize(shot, to: category) {
                preview.phase = .filed(moved)
            }
            scheduleHide(preview)
        }
    }

    private func hoverChanged(_ preview: CapturePreview, hovering: Bool) {
        preview.isHovered = hovering
        // Leaving restarts the countdown, so it doesn't vanish the moment the pointer moves off.
        if !hovering, preview.phase != .filing { scheduleHide(preview) }
    }

    // MARK: Showing and hiding

    private func show(_ preview: CapturePreview) {
        if previews.isEmpty { screen = Self.screenUnderPointer() }
        if previews.count == Self.maxVisible { dismiss(previews[0]) }

        let card = CapturePreviewView(
            preview: preview,
            onOpen: { [weak self] in self?.open(preview) },
            onClose: { [weak self] in self?.dismiss(preview) },
            onRecategorize: { [weak self] category in self?.recategorize(preview, to: category) }
        )
        .environment(model)
        .padding(CapturePreviewPanel.margin)
        let panel = CapturePreviewPanel(rootView: card) { [weak self] hovering in
            self?.hoverChanged(preview, hovering: hovering)
        }

        previews.append(preview)
        panels[preview.id] = panel
        layout(slidingIn: preview)
        scheduleHide(preview, after: Self.filingTimeout)
    }

    /// Hides `preview` after `delay`, or checks again later while it's in use.
    private func scheduleHide(_ preview: CapturePreview, after delay: Duration = hideDelay) {
        guard previews.contains(where: { $0 === preview }) else { return }
        hideTasks[preview.id]?.cancel()
        hideTasks[preview.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if isInUse(preview) {
                scheduleHide(preview)
            } else {
                dismiss(preview)
            }
        }
    }

    private func isInUse(_ preview: CapturePreview) -> Bool {
        preview.isHovered || openMenus > 0 || preview.shot.map(model.isRecategorizing) == true
    }

    private func dismiss(_ preview: CapturePreview) {
        guard let index = previews.firstIndex(where: { $0 === preview }) else { return }
        previews.remove(at: index)
        hideTasks.removeValue(forKey: preview.id)?.cancel()
        if let panel = panels.removeValue(forKey: preview.id) {
            let offscreen = panel.frame.offsetBy(dx: panel.frame.width, dy: 0)
            Self.animate({
                panel.animator().setFrame(offscreen, display: true)
                panel.animator().alphaValue = 0
            }, then: { panel.orderOut(nil) })
        }
        layout()
    }

    /// Stacks the panels up from the bottom-right corner, newest lowest. `newcomer` slides in
    /// from the right edge; the others glide to their new places.
    private func layout(slidingIn newcomer: CapturePreview? = nil) {
        guard let area = (screen ?? NSScreen.main)?.visibleFrame else { return }
        var y = area.minY + Self.screenInset
        for preview in previews.reversed() {
            guard let panel = panels[preview.id] else { continue }
            let size = panel.frame.size
            let target = NSRect(origin: NSPoint(x: area.maxX - Self.screenInset - size.width, y: y), size: size)
            y += size.height
            if preview === newcomer {
                panel.setFrame(NSRect(origin: NSPoint(x: area.maxX, y: target.minY), size: size), display: false)
                panel.alphaValue = 0
                // The app isn't active, so a plain orderFront wouldn't show it.
                panel.orderFrontRegardless()
            }
            Self.animate({
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }, then: {
                // The shadow is traced from what's drawn, which may have been nothing when
                // the panel first appeared.
                panel.invalidateShadow()
            })
        }
    }

    private static func animate(_ changes: () -> Void, then completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        } completionHandler: {
            MainActor.assumeIsolated(completion)
        }
    }

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }
}
