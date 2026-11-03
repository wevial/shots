import ShotsKit
import SwiftUI

/// Scopes: All, Needs Review, Failed, Clean Up, then one row per category, each with a count.
/// Categories with nothing in them fold under "More". Selecting a row sets `model.scope`.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarShowsEmptyCategories") private var showsEmpty = false

    var body: some View {
        // List(selection:) wants an optional binding; a nil selection (e.g. a click on empty
        // space) is ignored so the scope always stays valid.
        let selection = Binding<SidebarScope?>(
            get: { model.scope },
            set: { if let scope = $0 { model.scope = scope } }
        )

        List(selection: selection) {
            Section {
                row(.all)
                row(.review)
                row(.failed)
                row(.cleanup)
            }
            Section("Categories") {
                ForEach(filledCategories, id: \.self) { row(.category($0)) }
                if !emptyCategories.isEmpty {
                    DisclosureGroup("More", isExpanded: $showsEmpty) {
                        ForEach(emptyCategories, id: \.self) { row(.category($0)) }
                    }
                    .clickable()
                }
            }
        }
        // Below ~200 pt the section header and More's chevron get clipped.
        .navigationSplitViewColumnWidth(min: 205, ideal: 215, max: 280)
    }

    /// Categories that hold screenshots, plus the selected one so the selection never vanishes.
    private var filledCategories: [String] {
        model.categories.filter { model.counts.count(for: .category($0)) > 0 || model.scope == .category($0) }
    }

    private var emptyCategories: [String] {
        model.categories.filter { !filledCategories.contains($0) }
    }

    private func row(_ scope: SidebarScope) -> some View {
        SidebarRow(
            title: scope.title,
            systemImage: Self.symbol(for: scope),
            count: model.counts.count(for: scope),
            highlightsCount: scope == .review || scope == .failed,
            tint: Self.tint(for: scope)
        )
        .tag(scope)
        .clickable()
    }

    /// Categories get their own symbol; everything else uses the scope's default.
    private static func symbol(for scope: SidebarScope) -> String {
        if case .category(let name) = scope { return categorySymbol(name) }
        return scope.systemImage
    }

    private static func tint(for scope: SidebarScope) -> Color? {
        switch scope {
        case .category(let name): Theme.color(for: name)
        case .review: .orange
        case .failed: .red
        case .cleanup: .purple
        default: .accentColor
        }
    }

    static func categorySymbol(_ category: String) -> String {
        switch category {
        case "code": "chevron.left.forwardslash.chevron.right"
        case "design": "paintpalette"
        case "ui-reference": "rectangle.on.rectangle"
        case "docs": "doc.text"
        case "chat": "bubble.left.and.bubble.right"
        case "finance": "chart.line.uptrend.xyaxis"
        case "receipts": "receipt"
        case "shopping": "cart"
        case "travel": "airplane"
        case "social": "person.2"
        case "errors": "exclamationmark.triangle"
        case "misc": "tray"
        default: "folder"
        }
    }
}

/// One sidebar row. Review and Failed counts are shown as a badge when non-zero;
/// other counts are quiet secondary text.
private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let count: Int
    let highlightsCount: Bool
    var tint: Color?

    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if highlightsCount && count > 0 {
                    Text(count, format: .number)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(.red, in: .capsule)
                } else {
                    Text(count, format: .number)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint ?? .secondary)
        }
    }
}

#Preview {
    SidebarView()
        .environment(AppModel.preview())
        .frame(width: 240, height: 500)
}
