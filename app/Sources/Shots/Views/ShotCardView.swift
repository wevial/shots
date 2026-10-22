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
                .overlay(alignment: .bottom) {
                    if isHovered && shot.fileExists {
                        CopyStrip(shot: shot)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .clipShape(.rect(cornerRadius: 6))

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

            CategoryBadge(category: shot.category)
        }
        .padding(8)
        .modifier(CardSurface(isSelected: isSelected, isHovered: isHovered))
        .contentShape(.rect(cornerRadius: 14))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

/// The card's background: frosted glass over the backdrop, tinted and outlined when selected,
/// lifting a touch on hover.
private struct CardSurface: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.tint(isSelected ? Color.accentColor.opacity(0.35) : nil), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .scaleEffect(isHovered && !isSelected ? 1.015 : 1)
    }
}

/// A full-width "Copy" strip along the bottom of a hovered card's image: a big target that
/// doesn't change the card's size. Shows "Copied" for a moment after a click.
private struct CopyStrip: View {
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
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.callout.weight(.medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
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
