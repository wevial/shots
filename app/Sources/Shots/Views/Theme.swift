import SwiftUI

/// Colors and backdrops shared by the views.
enum Theme {
    /// One color per seed category; anything else gets a stable color from its name.
    static func color(for category: String) -> Color {
        let seeded: [String: Color] = [
            "code": .blue, "design": .pink, "ui-reference": .purple, "docs": .teal,
            "chat": .green, "finance": .mint, "receipts": .orange, "shopping": .yellow,
            "travel": .cyan, "social": .indigo, "errors": .red, "misc": .gray,
        ]
        if let color = seeded[category] { return color }
        let palette: [Color] = [.blue, .pink, .purple, .teal, .green, .orange, .cyan, .indigo]
        let hash = category.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}

/// A soft gradient in the app icon's colors, for glass to sit on. Quieter in light mode so
/// screenshots stay the loudest thing on screen.
struct Backdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.6, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                .indigo, .purple, .pink,
                .blue, .purple, .orange,
                .teal, .indigo, .purple,
            ]
        )
        .opacity(colorScheme == .dark ? 0.3 : 0.14)
        .background(Color(nsColor: .windowBackgroundColor))
        // Up under the title bar so it shares the surface; not under the sidebar.
        .ignoresSafeArea(edges: .top)
    }
}

/// The category capsule on cards and in the inspector.
struct CategoryBadge: View {
    let category: String
    var font: Font = .caption2.weight(.semibold)

    var body: some View {
        let color = Theme.color(for: category)
        Text(category)
            .font(font)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: .capsule)
            .lineLimit(1)
    }
}
