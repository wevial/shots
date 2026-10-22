import ShotsKit
import SwiftUI

/// The "Failed" scope: `model.failedJobs` with their errors, and Reveal in Finder / Quick Look.
struct FailedJobsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.failedJobs.isEmpty {
            ContentUnavailableView(
                "No Failed Screenshots",
                systemImage: "checkmark.circle",
                description: Text("Everything in the inbox was processed.")
            )
        } else {
            List(model.failedJobs) { job in
                FailedJobRow(job: job)
            }
        }
    }
}

private struct FailedJobRow: View {
    @Environment(AppModel.self) private var model
    let job: FailedJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailView(url: job.fileURL, maxSize: 72)
                .frame(width: 72, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.fileName)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = job.lastError, !error.isEmpty {
                    // Selectable so the message can be copied into a bug report.
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)

            HStack {
                Button("Reveal in Finder", systemImage: "folder") {
                    model.revealInFinder(job.fileURL)
                }
                Button("Quick Look", systemImage: "eye") {
                    model.quickLook(job.fileURL)
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!job.fileExists)
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        let attempts = job.attempts == 1 ? "1 attempt" : "\(job.attempts) attempts"
        let when = job.updatedAt.formatted(.relative(presentation: .named))
        return "\(attempts) · \(when)"
    }
}

#Preview("With failures") {
    FailedJobsView()
        .environment(AppModel.preview(scope: .failed))
        .frame(width: 600, height: 300)
}
