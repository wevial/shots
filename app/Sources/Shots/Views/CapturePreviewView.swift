import ShotsKit
import SwiftUI

/// The card in a "just captured" panel: the thumbnail, then "Copied" and "Filing…", then the
/// title with a category menu and Open (or a failure line with Show).
struct CapturePreviewView: View {
    @Environment(AppModel.self) private var model
    let preview: CapturePreview
    /// Opens the shot in Shots, or the Failed list for a failure.
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    var onRecategorize: @MainActor (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                switch preview.phase {
                case .filing: filing
                case .filed(let shot): filed(shot)
                case .failed: failed
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 330)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
        .overlay(alignment: .topLeading) {
            if preview.isHovered { closeButton }
        }
    }

    private var thumbnail: some View {
        ThumbnailView(url: preview.fileURL, maxSize: 96)
            .frame(width: 96, height: 64)
            .background(.quaternary.opacity(0.5))
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1)))
            // `fileURL` follows the file as it's filed and re-filed, so the drag always works.
            .draggable(preview.fileURL)
            .onTapGesture {
                if preview.phase != .filing { onOpen() }
            }
            .clickable()
    }

    @ViewBuilder
    private var filing: some View {
        if preview.copied {
            Label("Copied", systemImage: "checkmark")
                .font(.callout.weight(.medium))
        }
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Filing…")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func filed(_ shot: Shot) -> some View {
        Text(shot.displayTitle)
            .font(.callout.weight(.medium))
            .lineLimit(1)
        HStack(spacing: 6) {
            Picker("Category", selection: categoryBinding(shot)) {
                ForEach(categories(including: shot.category), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.isRecategorizing(shot))
            .clickable()

            Button("Open", action: onOpen)
                .clickable()

            if model.isRecategorizing(shot) {
                ProgressView().controlSize(.mini)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var failed: some View {
        Label("Couldn't file", systemImage: "exclamationmark.triangle")
            .font(.callout.weight(.medium))
        Button("Show", action: onOpen)
            .controlSize(.small)
            .clickable()
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark", action: onClose)
            .labelStyle(.iconOnly)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(Color(nsColor: .controlBackgroundColor), in: .circle)
            .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
            .buttonStyle(.plain)
            .clickable()
            // Straddles the card's corner, like a notification's close button.
            .offset(x: -6, y: -6)
    }

    /// Reads the shot's category; choosing another one re-files it.
    private func categoryBinding(_ shot: Shot) -> Binding<String> {
        Binding(get: { shot.category }, set: { onRecategorize($0) })
    }

    /// Configured categories, plus this shot's own if it isn't one of them.
    private func categories(including category: String) -> [String] {
        model.categories.contains(category) ? model.categories : model.categories + [category]
    }
}

// The panel adds the same transparent margin, so the close button has room on the corner.
private struct PreviewCard: View {
    let preview: CapturePreview

    var body: some View {
        CapturePreviewView(preview: preview)
            .environment(AppModel.preview())
            .padding(CapturePreviewPanel.margin)
    }
}

#Preview("Landed") {
    PreviewCard(preview: CapturePreview(id: 1, inboxPath: Shot.sample.path, copied: true))
}

#Preview("Landed, not copied") {
    PreviewCard(preview: CapturePreview(id: 1, inboxPath: Shot.sample.path, copied: false))
}

#Preview("Filed") {
    PreviewCard(preview: CapturePreview(id: 1, inboxPath: Shot.sample.path, copied: true, phase: .filed(.sample)))
}

#Preview("Filed, hovered") {
    PreviewCard(preview: CapturePreview(
        id: 1, inboxPath: Shot.sample.path, copied: true, phase: .filed(.sample), isHovered: true))
}

#Preview("Failed") {
    PreviewCard(preview: CapturePreview(
        id: 1, inboxPath: Shot.sample.path, copied: true, phase: .failed("all backends failed")))
}
