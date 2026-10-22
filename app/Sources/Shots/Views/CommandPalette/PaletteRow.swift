import SwiftUI

/// One palette row: icon (or thumbnail), title, and the shortcut or category on the right.
struct PaletteRow: View {
    static let height: CGFloat = 32

    let command: PaletteCommand
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 22, height: 18)

            Text(command.title)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let screenshot = command.screenshot {
                CategoryBadge(category: screenshot.category)
            } else if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.12))
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var leading: some View {
        if let screenshot = command.screenshot {
            ThumbnailView(url: screenshot.url, maxSize: 44)
                .clipShape(.rect(cornerRadius: 3))
        } else {
            Image(systemName: command.systemImage)
                .foregroundStyle(command.tint ?? .secondary)
        }
    }
}
