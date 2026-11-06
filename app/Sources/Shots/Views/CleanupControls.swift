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

/// Puts everything Clean Up shows (after any search) in Recently Deleted, once confirmed.
struct DeleteAllButton: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirming = false

    var body: some View {
        Button("Delete All", systemImage: "trash") { isConfirming = true }
            .disabled(model.shots.isEmpty)
            .clickable()
            .confirmationDialog(title, isPresented: $isConfirming) {
                Button("Delete", role: .destructive) {
                    let shots = model.shots
                    Task { await model.delete(shots) }
                }
            }
    }

    private var title: String {
        model.shots.count == 1 ? "Delete 1 screenshot?" : "Delete \(model.shots.count) screenshots?"
    }
}

#Preview("Check") {
    CheckOlderShotsButton()
        .environment(AppModel.preview(scope: .cleanup))
        .padding()
}
