import ShotsKit
import SwiftUI

/// Asks the classifier about shots filed before it judged scratch; shows progress and a Stop
/// button while it runs. Nothing when every shot has been judged.
struct CheckOlderShotsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let check = model.scratchCheck {
            HStack(spacing: 8) {
                ProgressView(value: Double(check.done), total: Double(max(check.total, 1)))
                    .frame(width: 80)
                Text("\(check.done) of \(check.total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Stop") { model.stopCheckingOlderShots() }
                    .clickable()
            }
        } else if model.counts.unjudged > 0 {
            Button("Check \(model.counts.unjudged) Older Screenshots", systemImage: "sparkles") { model.checkOlderShots() }
                .help("Runs the classifier on each one to spot scratch")
                .clickable()
        }
    }
}

/// Moves everything Clean Up shows (after any search) to the Trash, once confirmed.
struct TrashAllButton: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirming = false

    var body: some View {
        Button("Move All to Trash", systemImage: "trash") { isConfirming = true }
            .disabled(model.shots.isEmpty)
            .clickable()
            .confirmationDialog(title, isPresented: $isConfirming) {
                Button("Move to Trash", role: .destructive) {
                    let shots = model.shots
                    Task { await model.moveToTrash(shots) }
                }
            }
    }

    private var title: String {
        model.shots.count == 1 ? "Move 1 screenshot to the Trash?" : "Move \(model.shots.count) screenshots to the Trash?"
    }
}

#Preview("Check") {
    CheckOlderShotsButton()
        .environment(AppModel.preview(scope: .cleanup))
        .padding()
}
