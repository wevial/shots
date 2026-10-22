import ShotsKit
import SwiftUI

/// The content column: a grid of `ShotCardView`s for `model.shots`, bound to `model.selectedShotID`.
struct ShotGridView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]

    var body: some View {
        if model.shots.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            // Lazy: only cards near the viewport are built, so thousands of shots stay smooth.
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.shots) { shot in
                    ShotCardView(shot: shot, isSelected: shot.id == model.selectedShotID)
                        .onTapGesture { model.selectedShotID = shot.id }
                        .draggable(shot.fileURL)
                        .contextMenu { contextMenu(for: shot) }
                }
            }
            .padding()
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
