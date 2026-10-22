import ShotsKit
import SwiftUI

/// One grid card: thumbnail, title, relative date, category and review badges, a spinner
/// while a recat is running on it, and a copy button while hovered.
struct ShotCardView: View {
    @Environment(AppModel.self) private var model
    let shot: Shot
    var isSelected = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailView(url: shot.fileURL, maxSize: 360)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                .overlay {
                    if model.isRecategorizing(shot) {
                        ProgressView()
                            .padding(10)
                            .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isHovered && shot.fileExists {
                        CopyImageButton(shot: shot)
                            .padding(6)
                            .transition(.opacity)
                    }
                }

            Text(shot.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(shot.capturedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if shot.needsReview {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .help("Needs review")
                }
            }

            Text(shot.category)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: .capsule)
                .lineLimit(1)
        }
        .padding(8)
        .background(isSelected ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(.rect(cornerRadius: 10))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

/// The two-squares copy button on a hovered card; shows a checkmark for a moment after copying.
private struct CopyImageButton: View {
    @Environment(AppModel.self) private var model
    let shot: Shot
    @State private var copied = false

    var body: some View {
        Button {
            model.copyImage(shot)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Copy Image")
    }
}

#Preview("Cards") {
    HStack {
        ShotCardView(shot: Shot.samples[0], isSelected: true)
        ShotCardView(shot: Shot.samples[2])
        ShotCardView(shot: Shot.missingFileSample)
    }
    .padding()
    .environment(AppModel.preview())
}

#Preview("Recategorizing") {
    let model = AppModel.preview()
    model.previewRecategorizing(.sample)
    return ShotCardView(shot: .sample)
        .frame(width: 200)
        .padding()
        .environment(model)
}
