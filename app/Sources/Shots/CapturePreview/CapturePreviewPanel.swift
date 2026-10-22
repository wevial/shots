import AppKit
import SwiftUI

/// A borderless panel that floats over every app and Space without taking focus: clicking it
/// leaves the app you're in frontmost, like the system's screenshot thumbnail.
final class CapturePreviewPanel: NSPanel {
    /// Transparent space around the card, so the close button can straddle its corner.
    static let margin: CGFloat = 8

    init(rootView: some View, onHover: @escaping (Bool) -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Panels hide when their app deactivates by default, and Shots is almost never active.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        // The window server shapes the shadow to the card's rounded corners.
        hasShadow = true

        let host = PanelHostingView(rootView: AnyView(rootView))
        host.onHover = onHover
        contentView = host
        setContentSize(host.fittingSize)
    }

    // Never key or main, so it can't take focus or turn Shots into a regular app
    // (see ActivationPolicy).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PanelHostingView: NSHostingView<AnyView> {
    var onHover: (Bool) -> Void = { _ in }
    private var hoverArea: NSTrackingArea?

    /// The panel is never key, so without this the first click would only be swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Hover is tracked here rather than with SwiftUI's .onHover, with an .activeAlways area,
    // so it works while another app is active (which is nearly always, right after a capture).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    // Other tracking areas (SwiftUI's) can report to this view as well; only ours means "the panel".
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { onHover(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { onHover(false) }
    }
}
