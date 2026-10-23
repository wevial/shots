import SwiftUI

/// The search field pinned above the grid. It lives in the content rather than the toolbar so
/// it never drops out at narrow widths or drifts over the inspector.
struct SearchBar: View {
    @Binding var text: String
    var focus: FocusState<ContentView.Pane?>.Binding
    /// ↓ or Return: hand the keyboard to the grid.
    var onMoveToResults: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search screenshots", text: $text)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("search") // stable handle for UI automation (scripts/ui-smoke)
                .focused(focus, equals: .search)
                .onKeyPress(.downArrow) {
                    onMoveToResults()
                    return .handled
                }
                .onSubmit(onMoveToResults)
                .onKeyPress(.escape) {
                    if text.isEmpty { onMoveToResults() } else { text = "" }
                    return .handled
                }
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .clickable()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassEffect(.regular.interactive(), in: .capsule)
        // A min width, or the text field's own ideal width props the whole column open and the
        // window ends up wider than itself at small sizes, clipping the sidebar.
        .frame(minWidth: 140, idealWidth: 260, maxWidth: 520)
    }
}
