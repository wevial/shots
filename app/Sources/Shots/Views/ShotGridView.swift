import ShotsKit
import SwiftUI

/// The content column: a grid of `ShotCardView`s for `model.shots`, bound to `model.selectedShotID`.
struct ShotGridView: View {
    @Environment(AppModel.self) private var model

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
            ScrollView {
                cards(columns: Array(repeating: GridItem(.fixed(Self.cardWidth), spacing: Self.spacing), count: count))
                    .animation(.smooth(duration: 0.35), value: count)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let shot = model.selectedShot else { return .ignored }
            model.quickLook(shot)
            return .handled
        }
        .onTapGesture { model.selectedShotID = nil } // Click on empty space deselects.
    }

    private func cards(columns: [GridItem]) -> some View {
        // Lazy: only cards near the viewport are built, so thousands of shots stay smooth.
        LazyVGrid(columns: columns, spacing: Self.spacing) {
            ForEach(model.shots) { shot in
                ShotCardView(shot: shot, isSelected: shot.id == model.selectedShotID)
                    .onTapGesture { model.selectedShotID = shot.id }
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

#Preview("Grid") {
    ShotGridView()
        .environment(AppModel.preview(selecting: Shot.samples[1]))
        .frame(width: 640, height: 480)
}

#Preview("Empty") {
    ShotGridView()
        .environment(AppModel.preview(scope: .category("nothing-here")))
        .frame(width: 400, height: 300)
}
