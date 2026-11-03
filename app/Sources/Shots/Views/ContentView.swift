import QuickLook
import ShotsKit
import SwiftUI

/// The main window: sidebar, the grid (or failed jobs), and an inspector for the selection.
struct ContentView: View {
    /// What has the keyboard: the search field or the grid (Tab moves between them and the rest).
    enum Pane: Hashable { case search, grid }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(MainWindowState.self) private var window
    @FocusState private var focus: Pane?

    var body: some View {
        // @Bindable turns the environment model into bindings ($model.searchText).
        @Bindable var model = model
        @Bindable var window = window

        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
                // Fill the column whatever it shows: an empty state is only as big as its text,
                // and the backdrop behind it would otherwise paint just that rectangle.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .inspector(isPresented: $window.showsInspector) {
                    inspector
                        // A fixed ideal width: otherwise the column follows its content's, which
                        // for a selected shot (long OCR lines, URLs) is far wider than "No Selection",
                        // so the inspector jumped wider on every selection.
                        .frame(minWidth: 0, idealWidth: 320, maxWidth: .infinity)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.loginItem.wasOffered {
                LaunchAtLoginBanner()
            }
        }
        // While the palette is up, everything behind it is inert, so the search field or the
        // grid can't keep (or take back) the keyboard from the palette's field.
        .disabled(window.showsPalette)
        .overlay {
            if window.showsPalette {
                CommandPalette(isPresented: $window.showsPalette, showsInspector: $window.showsInspector) {
                    ActivationPolicy.shared.activateForWindow()
                    openWindow(id: "status")
                }
            }
        }
        // Back to the grid after the palette closes, so arrow keys work straight away.
        .onChange(of: window.showsPalette) { _, open in if !open { focus = .grid } }
        .toolbar {
            if model.scope == .cleanup && !model.shots.isEmpty {
                ToolbarItemGroup(placement: .primaryAction) {
                    CheckOlderShotsButton()
                    TrashAllButton()
                }
            }
            ToolbarItem(placement: .primaryAction) { inspectorToggle }
        }
        .onChange(of: window.searchFocusRequests) { focus = .search }
        .quickLookPreview($model.quickLookURL)
        .alert("Something went wrong", isPresented: $model.isShowingError, presenting: model.lastError) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        // The narrowest layout that doesn't clip: the grid column sits under the floating
        // sidebar, so the sidebar counts twice, plus one card column, plus the inspector if open.
        .frame(minWidth: window.showsInspector ? 950 : 720, minHeight: 500)
    }

    /// From the search field into the results, selecting the first one if nothing is selected.
    private func focusGrid() {
        if model.selectedShotID == nil { model.selectedShotID = model.shots.first?.id }
        focus = .grid
    }

    private var inspectorToggle: some View {
        Button("Inspector", systemImage: "sidebar.trailing") { window.showsInspector.toggle() }
            .help(window.showsInspector ? "Hide Inspector" : "Show Inspector")
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
        .environment(MainWindowState())
}

#Preview("Clean Up") {
    ContentView()
        .environment(AppModel.preview(scope: .cleanup, selecting: Shot.samples[1]))
        .environment(MainWindowState())
}

#Preview("Needs Review") {
    ContentView()
        .environment(AppModel.preview(scope: .review))
        .environment(MainWindowState())
}
