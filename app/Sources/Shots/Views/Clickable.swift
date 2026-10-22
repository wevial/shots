import SwiftUI

extension View {
    /// The pointing-hand cursor, for anything you can click. AppKit only shows it for links
    /// by default, so buttons, cards and rows opt in with this.
    func clickable() -> some View {
        pointerStyle(.link)
    }
}
