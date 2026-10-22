import ShotsKit
import SwiftUI

/// A Quick Look thumbnail of the file at `url` (via `Thumbnails.shared`), or a
/// "File missing" placeholder when it isn't there.
struct ThumbnailView: View {
    let url: URL
    /// The longest side to render, in points.
    var maxSize: CGFloat = 240

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var didFinish = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFit()
            } else if didFinish {
                ContentUnavailableView("File missing", systemImage: "questionmark.square.dashed")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            } else {
                Color.clear // Loading: keep the layout stable without flashing a placeholder.
            }
        }
        // .task(id:) restarts when the URL changes (e.g. after a recat moves the file) and is
        // cancelled automatically when the view scrolls away.
        .task(id: url) {
            didFinish = false
            let loaded = await Thumbnails.shared.image(
                for: url, size: CGSize(width: maxSize, height: maxSize), scale: displayScale)
            guard !Task.isCancelled else { return } // Scrolled away; don't claim the file is missing.
            image = loaded
            didFinish = true
        }
    }
}

#Preview {
    ThumbnailView(url: Shot.sample.fileURL)
        .frame(width: 200, height: 160)
}

#Preview("File missing") {
    ThumbnailView(url: Shot.missingFileSample.fileURL)
        .frame(width: 200, height: 160)
}
