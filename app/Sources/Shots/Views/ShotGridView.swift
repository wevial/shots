import ShotsKit
import SwiftUI
import UniformTypeIdentifiers

/// The content column: a grid of `ShotCardView`s for `model.shots`, bound to `model.selectedShotID`.
struct ShotGridView: View {
    @Environment(AppModel.self) private var model
    var focus: FocusState<ContentView.Pane?>.Binding

    // Cards keep one size; resizing the window only changes how many fit in a row, and the
    // cards glide to their new places when that number changes.
    private static let cardWidth: CGFloat = 220
    private static let spacing: CGFloat = 12
    private static let padding: CGFloat = 16

    /// How many fixed-width cards fit across `width`.
    private static func columnCount(for width: CGFloat) -> Int {
        let usable = width - 2 * padding + spacing
        return max(1, Int(usable / (cardWidth + spacing)))
    }

    var body: some View {
        if model.shots.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var grid: some View {
        // The column count is derived from the width on every layout pass rather than stored:
        // writing it to @State from a geometry callback re-entered layout and crashed.
        GeometryReader { proxy in
            let count = Self.columnCount(for: proxy.size.width)
            ScrollViewReader { scroller in
                ScrollView {
                    cards(columns: Array(repeating: GridItem(.fixed(Self.cardWidth), spacing: Self.spacing), count: count))
                        .animation(.smooth(duration: 0.35), value: count)
                }
                // Inside the GeometryReader so ↑/↓ know how many cards make a row.
                .focusable()
                .focused(focus, equals: .grid)
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    moveSelection(press.key, columns: count)
                    return .handled
                }
                .onKeyPress(.space) { run { model.quickLook($0) } }
                .onKeyPress(.return) { run { model.open($0) } }
                .onKeyPress(.escape) {
                    guard model.selectedShotID != nil else { return .ignored }
                    model.selectedShotID = nil
                    return .handled
                }
                .onCopyCommand { model.selectedShot.flatMap(Self.imageProvider).map { [$0] } ?? [] }
                .onChange(of: model.selectedShotID) { _, id in
                    guard let id else { return }
                    withAnimation(.smooth(duration: 0.2)) { scroller.scrollTo(id) }
                }
            }
        }
        // An explicit minimum of one card: otherwise the grid's current width (n fixed columns)
        // becomes its minimum, the column can't shrink, and the sidebar gets squeezed instead.
        .frame(minWidth: Self.cardWidth + 2 * Self.padding, idealWidth: Self.cardWidth + 2 * Self.padding, maxWidth: .infinity)
        .onTapGesture { model.selectedShotID = nil } // Click on empty space deselects.
    }

    /// Arrow keys walk the grid in reading order; up/down jump a whole row.
    private func moveSelection(_ key: KeyEquivalent, columns: Int) {
        let shots = model.shots
        guard !shots.isEmpty else { return }
        guard let current = shots.firstIndex(where: { $0.id == model.selectedShotID }) else {
            model.selectedShotID = shots.first?.id
            return
        }
        let step = switch key {
        case .leftArrow: -1
        case .rightArrow: 1
        case .upArrow: -columns
        default: columns
        }
        model.selectedShotID = shots[min(max(current + step, 0), shots.count - 1)].id
    }

    private func run(_ action: (Shot) -> Void) -> KeyPress.Result {
        guard let shot = model.selectedShot else { return .ignored }
        action(shot)
        return .handled
    }

    /// ⌘C puts the image itself on the pasteboard (as PNG when it is one), not a file reference.
    private static func imageProvider(for shot: Shot) -> NSItemProvider? {
        guard let data = try? Data(contentsOf: shot.fileURL) else { return nil }
        let type: UTType = shot.fileURL.pathExtension.lowercased() == "png" ? .png : .image
        return NSItemProvider(item: data as NSData, typeIdentifier: type.identifier)
    }

    private func cards(columns: [GridItem]) -> some View {
        // Lazy: only cards near the viewport are built, so thousands of shots stay smooth.
        LazyVGrid(columns: columns, spacing: Self.spacing) {
            ForEach(model.shots) { shot in
                ShotCardView(shot: shot, isSelected: shot.id == model.selectedShotID)
                    .id(shot.id)
                    .onTapGesture {
                        model.selectedShotID = shot.id
                        focus.wrappedValue = .grid
                    }
                    .clickable()
                    .draggable(shot.fileURL)
                    .contextMenu { contextMenu(for: shot) }
            }
        }
        .padding(Self.padding)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView(
                "No Screenshots", systemImage: "photo.on.rectangle",
                description: Text("Nothing in \(model.scope.title) yet."))
        }
    }

    @ViewBuilder
    private func contextMenu(for shot: Shot) -> some View {
        let busy = model.isRecategorizing(shot)

        Menu("Move to") {
            ForEach(model.categories, id: \.self) { category in
                Button(category) { Task { await model.recategorize(shot, to: category) } }
            }
        }
        .disabled(busy)

        Menu("Re-run with") {
            ForEach(ClassifierBackend.rerunnable) { backend in
                Button(backend.displayName) { Task { await model.rerun(shot, backend: backend) } }
            }
        }
        .disabled(busy)

        Divider()
        Button("Quick Look") { model.quickLook(shot) }
        Button("Reveal in Finder") { model.revealInFinder(shot) }
        Divider()
        Button("Copy Image") { model.copyImage(shot) }
        Button("Copy Path") { model.copyPath(shot) }
    }
}

/// Previews need somewhere to keep the focus state the grid binds to.
private struct GridPreviewHost: View {
    @FocusState private var focus: ContentView.Pane?
    var body: some View { ShotGridView(focus: $focus) }
}

#Preview("Grid") {
    GridPreviewHost()
        .environment(AppModel.preview(selecting: Shot.samples[1]))
        .frame(width: 640, height: 480)
}

#Preview("Empty") {
    GridPreviewHost()
        .environment(AppModel.preview(scope: .category("nothing-here")))
        .frame(width: 400, height: 300)
}
