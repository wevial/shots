import QuickLook
import ShotsKit
import SwiftUI

/// The main window: sidebar, the grid (or failed jobs), and an inspector for the selection.
struct ContentView: View {
    /// What has the keyboard: the search field or the grid (Tab moves between them and the rest).
    enum Pane: Hashable { case search, grid }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showsInspector = true
    @State private var showsPalette = false
    @FocusState private var focus: Pane?

    var body: some View {
        // @Bindable turns the environment model into bindings ($model.searchText).
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    // Failed jobs aren't searchable, so the field would do nothing there.
                    if model.scope != .failed {
                        SearchBar(text: $model.searchText, focus: $focus, onMoveToResults: focusGrid)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                    }
                }
                .navigationTitle(model.scope.title)
                .background { Backdrop() }
                // Let the backdrop show through the title bar instead of an opaque strip.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                // On the detail column, not the split view: wrapped around the whole split, the
                // inspector stopped the window from shrinking and the sidebar got clipped.
                .inspector(isPresented: $showsInspector) {
                    inspector
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.loginItem.wasOffered {
                LaunchAtLoginBanner()
            }
        }
        .overlay {
            if showsPalette {
                CommandPalette(isPresented: $showsPalette, showsInspector: $showsInspector) {
                    ActivationPolicy.shared.activateForWindow()
                    openWindow(id: "status")
                }
            }
        }
        // Back to the grid after the palette closes, so arrow keys work straight away.
        .onChange(of: showsPalette) { _, open in if !open { focus = .grid } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { inspectorToggle }
        }
        .focusedSceneValue(\.windowActions, WindowActions(
            focusSearch: { focus = .search },
            toggleInspector: { showsInspector.toggle() },
            openPalette: { showsPalette = true }
        ))
        .quickLookPreview($model.quickLookURL)
        .alert("Something went wrong", isPresented: $model.isShowingError, presenting: model.lastError) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        // The narrowest layout that doesn't clip: the grid column sits under the floating
        // sidebar, so the sidebar counts twice, plus one card column, plus the inspector if open.
        .frame(minWidth: showsInspector ? 950 : 720, minHeight: 500)
    }

    /// From the search field into the results, selecting the first one if nothing is selected.
    private func focusGrid() {
        if model.selectedShotID == nil { model.selectedShotID = model.shots.first?.id }
        focus = .grid
    }

    private var inspectorToggle: some View {
        Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
            .help(showsInspector ? "Hide Inspector" : "Show Inspector")
            .clickable()
    }

    @ViewBuilder
    private var detail: some View {
        if let setupError = model.setupError {
            ContentUnavailableView("Can't Read Screenshots", systemImage: "externaldrive.badge.exclamationmark", description: Text(setupError))
        } else if model.isLoading {
            ProgressView()
        } else if model.scope == .failed {
            FailedJobsView()
        } else {
            ShotGridView(focus: $focus)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let shot = model.selectedShot {
            InspectorView(shot: shot)
        } else {
            ContentUnavailableView("No Selection", systemImage: "photo", description: Text("Select a screenshot to see its details."))
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel.preview(selecting: Shot.sample))
}

#Preview("Needs Review") {
    ContentView()
        .environment(AppModel.preview(scope: .review))
}
