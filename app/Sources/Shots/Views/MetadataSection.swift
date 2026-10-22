import ShotsKit
import SwiftUI

/// The shot's metadata as label/value rows. Rows with no value are skipped.
struct MetadataSection: View {
    let shot: Shot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("App", shot.appName)
            row("Window", shot.windowTitle)
            if let url = shot.pageURL {
                MetadataRow(label: "URL") {
                    Link(shot.pageTitle ?? url.absoluteString, destination: url)
                        .lineLimit(2)
                }
            }
            row("Capture", shot.captureType)
            row("Size", shot.pixelSize)
            row("Confidence", shot.confidence.formatted(.percent.precision(.fractionLength(0))))
            row("Backend", shot.classifierBackend?.displayName ?? shot.backend)
            row("Captured", shot.capturedAt.formatted(date: .abbreviated, time: .shortened))
            row("Processed", shot.processedAt.formatted(date: .abbreviated, time: .shortened))
            row("Original", shot.originalName)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            MetadataRow(label: label) { Text(value).textSelection(.enabled) }
        }
    }
}

private struct MetadataRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    MetadataSection(shot: .sample)
        .frame(width: 320)
        .padding()
}
