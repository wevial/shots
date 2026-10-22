import ShotsKit
import SwiftUI

/// One grid card: thumbnail, title, relative date, category and review badges, and a spinner
/// while a recat is running on it.
struct ShotCardView: View {
    @Environment(AppModel.self) private var model
    let shot: Shot
    var isSelected = false

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
