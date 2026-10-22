import AppKit

/// Shots is a menu bar app (LSUIElement), so it has no Dock icon or menu bar of its own. While
/// a real window is open it becomes a regular app, so the window behaves normally; when the
/// last one closes it goes back to the menu bar.
@MainActor
final class ActivationPolicy {
    static let shared = ActivationPolicy()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.setActivationPolicy(.regular) } as Void
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // queue: .main means this already runs on the main thread; the compiler can't see that.
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                let closing = note.object as? NSWindow
                let othersOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.isContentWindow($0) }
                if !othersOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// Opens a window from the menu bar: the policy must change before the app is activated.
    func activateForWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// The menu bar item's own window and panels, such as the capture previews, don't count.
    static func isContentWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeMain && window.styleMask.contains(.titled)
    }
}
