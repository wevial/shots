import ShotsKit
import SwiftUI

@main
struct ShotsApp: App {
    // One model for the whole app, shared by the window and the menu bar.
    @State private var model: AppModel

    init() {
        let model = AppModel()
        // Start here rather than in a view's .task: the menu bar badge needs data even
        // while the main window is closed.
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        Window("Shots", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
    }
}
