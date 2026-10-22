import QuickLook
import ShotsKit
import SwiftUI

/// The main window: sidebar, the grid (or failed jobs), and an inspector for the selection.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showsInspector = true

    var body: some View {
        // @Bindable turns the environment model into bindings ($model.searchText).
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
                .navigationTitle(model.scope.title)
                // On the detail column, so the field sits in its toolbar, left of the inspector.
                .searchable(text: $model.searchText, placement: .toolbarPrincipal, prompt: "Search screenshots")
                .background { Backdrop() }
                // Let the backdrop show through the title bar instead of an opaque strip.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.loginItem.wasOffered {
                LaunchAtLoginBanner()
            }
        }
        .inspector(isPresented: $showsInspector) {
            inspector
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                // While open, the toggle sits over the inspector, so search keeps the grid's toolbar.
                .toolbar {
                    ToolbarItem { inspectorToggle }
                }
        }
        .toolbar {
            if !showsInspector {
                ToolbarItem(placement: .primaryAction) { inspectorToggle }
            }
        }
        .quickLookPreview($model.quickLookURL)
        .alert("Something went wrong", isPresented: $model.isShowingError, presenting: model.lastError) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .frame(minWidth: 800, minHeight: 500)
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
            ShotGridView()
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
