import ShotsKit
import SwiftUI

/// Details and actions for one shot: preview, category picker, re-run buttons, tags,
/// metadata, OCR text, and file buttons.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let shot: Shot

    private var isBusy: Bool { model.isRecategorizing(shot) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ThumbnailView(url: shot.fileURL, maxSize: 480)
                    .frame(maxWidth: .infinity)
                    .draggable(shot.fileURL)

                Text(shot.displayTitle)
                    .font(.title3.bold())
                    .textSelection(.enabled)

                categorySection

                if shot.needsReview, let suggestion = shot.suggestedCategory {
                    suggestionCallout(suggestion)
                }

                rerunSection

                if !shot.tags.isEmpty {
                    TagChipsView(tags: shot.tags)
                }

                Divider()
                MetadataSection(shot: shot)

                if !shot.ocrText.isEmpty {
                    Divider()
                    ocrSection
                }

                Divider()
                fileButtons
            }
            .padding()
        }
    }

    // MARK: - Sections

    private var categorySection: some View {
        HStack {
            Picker("Category", selection: categoryBinding) {
                ForEach(pickerCategories, id: \.self) { Text($0).tag($0) }
            }
            if isBusy { ProgressView().controlSize(.small) }
        }
        .disabled(isBusy)
    }

    private func suggestionCallout(_ suggestion: String) -> some View {
        HStack {
            Label {
                Text("Suggested: **\(suggestion)**")
            } icon: {
                Image(systemName: "exclamationmark.bubble")
            }
            Spacer()
            Button("Accept") {
                Task { await model.recategorize(shot, to: suggestion) }
            }
            .disabled(isBusy)
        }
        .padding(10)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 8))
    }

    private var rerunSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Re-run with")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                ForEach(ClassifierBackend.rerunnable) { backend in
                    Button(backend.displayName) {
                        Task { await model.rerun(shot, backend: backend) }
                    }
                }
                if isBusy { ProgressView().controlSize(.small) }
            }
            .disabled(isBusy)
        }
    }

    private var ocrSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Text")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(shot.ocrText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 160)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        }
    }

    private var fileButtons: some View {
        let buttons = Group {
            Button("Quick Look", systemImage: "eye") { model.quickLook(shot) }
            Button("Reveal", systemImage: "folder") { model.revealInFinder(shot) }
            Button("Open", systemImage: "arrow.up.forward.app") { model.open(shot) }
            Button("Copy", systemImage: "doc.on.doc") { model.copyImage(shot) }
        }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) {
            buttons
        }
        .controlSize(.small)
    }

    // MARK: - Category helpers

    /// Reads the shot's category; writing it asks the CLI to move the file.
    private var categoryBinding: Binding<String> {
        Binding(
            get: { shot.category },
            set: { newValue in
                Task { await model.recategorize(shot, to: newValue) }
            }
        )
    }

    /// Configured categories, plus this shot's own if it isn't one of them.
    private var pickerCategories: [String] {
        model.categories.contains(shot.category) ? model.categories : model.categories + [shot.category]
    }
}

#Preview("Classified") {
    InspectorView(shot: .sample)
        .environment(AppModel.preview(selecting: .sample))
        .frame(width: 320, height: 800)
}

#Preview("Needs review") {
    InspectorView(shot: Shot.samples[2])
        .environment(AppModel.preview(selecting: Shot.samples[2]))
        .frame(width: 320, height: 800)
}

#Preview("Recategorizing") {
    let model = AppModel.preview(selecting: .sample)
    model.previewRecategorizing(.sample)
    return InspectorView(shot: .sample)
        .environment(model)
        .frame(width: 320, height: 800)
}

#Preview("File missing") {
    InspectorView(shot: .missingFileSample)
        .environment(AppModel.preview())
        .frame(width: 320, height: 800)
}
