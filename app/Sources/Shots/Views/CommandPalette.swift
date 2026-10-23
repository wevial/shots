import AppKit
import ShotsKit
import SwiftUI

/// The ⌘K palette: a search field over every command and screenshot. ↑/↓ move the highlight,
/// Return runs it, Esc or a click outside closes. Fills its container with a dimmed backdrop.
struct CommandPalette: View {
    @Binding var isPresented: Bool
    @Binding var showsInspector: Bool
    var openStatusWindow: () -> Void

    @Environment(AppModel.self) private var model
    @AppStorage(CapturePreviewController.enabledKey) private var showsCapturePreview = true

    @State private var query: String
    @State private var foundShots: [Shot] = []
    /// Nil means the first row. Typing resets it.
    @State private var highlightedID: PaletteCommand.ID?
    @State private var lastPointerLocation: CGPoint?
    @FocusState private var isFieldFocused: Bool

    private static let width: CGFloat = 560
    private static let maxVisibleRows: CGFloat = 9
    private static let headerHeight: CGFloat = 28
    private static let listPadding: CGFloat = 6

    init(
        isPresented: Binding<Bool>,
        showsInspector: Binding<Bool>,
        openStatusWindow: @escaping () -> Void,
        query: String = ""
    ) {
        _isPresented = isPresented
        _showsInspector = showsInspector
        self.openStatusWindow = openStatusWindow
        _query = State(initialValue: query)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { isPresented = false }

            panel
                .padding(.top, 64)
                .padding(.horizontal, 24)
        }
        .task(id: query) { await searchShots() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            // Built once per update: every row's highlight and the list's height read it.
            results(sections)
        }
        .frame(maxWidth: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Type a command or screenshot…", text: $query)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("palette") // stable handle for UI automation (scripts/ui-smoke)
                .focused($isFieldFocused)
                .onSubmit { run(highlighted(in: sections.flatMap(\.commands))) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.escape) {
                    isPresented = false
                    return .handled
                }
        }
        .font(.title3)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .defaultFocus($isFieldFocused, true)
        .task {
            // onAppear is too early on macOS: the field isn't in the window yet, so the focus
            // request is dropped. One turn of the run loop later it sticks.
            await Task.yield()
            isFieldFocused = true
        }
        .onAppear { lastPointerLocation = NSEvent.mouseLocation }
    }

    // MARK: - Results

    private func results(_ sections: [PaletteSection]) -> some View {
        let rows = sections.flatMap(\.commands)
        let highlightedRowID = highlighted(in: rows)?.id
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if sections.isEmpty {
                        Text("No results")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: PaletteRow.height)
                    }
                    ForEach(sections) { section in
                        sectionHeader(section.title)
                        ForEach(section.commands) { command in
                            row(command, isHighlighted: command.id == highlightedRowID)
                        }
                    }
                }
                .padding(Self.listPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight(rowCount: rows.count, headerCount: sections.count))
            .onChange(of: query) {
                highlightedID = nil
                proxy.scrollTo(rows.first?.id)
            }
            .onChange(of: highlightedID) { _, id in
                // A nil anchor scrolls only as far as needed to bring the row into view.
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
            .frame(height: Self.headerHeight, alignment: .bottom)
    }

    private func row(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        Button { run(command) } label: {
            PaletteRow(command: command, isHighlighted: isHighlighted)
        }
        .buttonStyle(.plain)
        .clickable()
        .id(command.id)
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            // While the arrow keys scroll the list, rows slide under a resting pointer and
            // report hovers; only an actual mouse move should take the highlight.
            let location = NSEvent.mouseLocation
            guard location != lastPointerLocation else { return }
            lastPointerLocation = location
            highlightedID = command.id
        }
    }

    /// Rows and headers have fixed heights, so the list can be sized to its content up to
    /// `maxVisibleRows` and scroll beyond that.
    private func listHeight(rowCount: Int, headerCount: Int) -> CGFloat {
        let content = CGFloat(max(1, rowCount)) * PaletteRow.height + CGFloat(headerCount) * Self.headerHeight
        // Half a row more than the limit, so a cut-off row hints that the list scrolls.
        let maximum = (Self.maxVisibleRows + 0.5) * PaletteRow.height + Self.headerHeight
        return min(content, maximum) + 2 * Self.listPadding
    }

    // MARK: - Commands

    private var sections: [PaletteSection] {
        var commands: [PaletteSection] = []
        if let shot = model.selectedShot {
            commands.append(.selection(shot, model: model))
        }
        commands.append(.goTo(model: model))
        commands.append(.app(
            model: model,
            showsInspector: $showsInspector,
            showsCapturePreview: $showsCapturePreview,
            openStatusWindow: openStatusWindow
        ))

        var sections = commands.matching(query)
        if !query.isEmpty, !foundShots.isEmpty {
            sections.append(.screenshots(foundShots, model: model))
        }
        return sections
    }

    private func highlighted(in rows: [PaletteCommand]) -> PaletteCommand? {
        rows.first { $0.id == highlightedID } ?? rows.first
    }

    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        let rows = sections.flatMap(\.commands)
        guard !rows.isEmpty else { return .handled }
        let current = rows.firstIndex { $0.id == highlighted(in: rows)?.id } ?? 0
        // Wraps around, so ↑ from the first row reaches the last.
        let next = (current + offset + rows.count) % rows.count
        highlightedID = rows[next].id
        return .handled
    }

    /// Closes first, so whatever the command opens (Quick Look, a window) isn't covered.
    private func run(_ command: PaletteCommand?) {
        guard let command else { return }
        isPresented = false
        command.run()
    }

    private func searchShots() async {
        guard !query.isEmpty else {
            foundShots = []
            return
        }
        // A short pause in typing before hitting the index; a new keystroke cancels this task.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let shots = await model.searchAllShots(query, limit: 6)
        guard !Task.isCancelled else { return }
        foundShots = shots
    }
}

#Preview("Empty query") {
    CommandPalette(isPresented: .constant(true), showsInspector: .constant(true), openStatusWindow: {})
        .environment(AppModel.preview())
        .frame(width: 900, height: 600)
        .background { Backdrop() }
}

#Preview("Query") {
    CommandPalette(isPresented: .constant(true), showsInspector: .constant(true), openStatusWindow: {}, query: "re")
        .environment(AppModel.preview(selecting: .sample))
        .frame(width: 900, height: 600)
        .background { Backdrop() }
}

#Preview("Selection") {
    CommandPalette(isPresented: .constant(true), showsInspector: .constant(true), openStatusWindow: {})
        .environment(AppModel.preview(selecting: Shot.samples[2]))
        .frame(width: 900, height: 600)
        .background { Backdrop() }
}
