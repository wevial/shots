import ShotsKit
import SwiftUI

/// Details and actions for one shot: preview, title, action tiles, category and re-run menus,
/// review suggestion, tags, metadata, and OCR text.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let shot: Shot

    private var isBusy: Bool { model.isRecategorizing(shot) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ThumbnailView(url: shot.fileURL, maxSize: 480)
                    .frame(maxWidth: .infinity)
                    .draggable(shot.fileURL)

                Text(shot.displayTitle)
                    .font(.title3.bold())
                    .textSelection(.enabled)

                ActionTiles(shot: shot)

                classificationMenus

                if shot.needsReview, let suggestion = shot.suggestedCategory {
                    suggestionCallout(suggestion)
                }

                if !shot.tags.isEmpty {
                    TagChipsView(tags: shot.tags)
                }

                Divider()
                MetadataSection(shot: shot)

                if !shot.ocrText.isEmpty {
                    Divider()
                    ocrSection
                }
            }
            .padding()
        }
    }

    // MARK: - Sections

    /// Category and re-run as two compact menus on one row; the shot's current category is
    /// checked. Choosing either moves the file, so both lock while a recat runs.
    private var classificationMenus: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Category", selection: categoryBinding) {
                    ForEach(pickerCategories, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(shot.category)
            }
            .fixedSize()
            .clickable()

            Menu {
                ForEach(ClassifierBackend.rerunnable) { backend in
                    Button(backend.displayName) {
                        Task { await model.rerun(shot, backend: backend) }
                    }
                }
            } label: {
                Label("Re-run", systemImage: "arrow.clockwise")
            }
            .fixedSize()
            .clickable()

            if isBusy { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
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
            .clickable()
            .disabled(isBusy)
        }
        .padding(10)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 8))
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

    // MARK: - Category helpers

    /// Reads the shot's category; writing it re-files the shot.
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

/// Copy, Quick Look, Reveal, Open as four equal tiles. Copy flips to "Copied" for a moment.
private struct ActionTiles: View {
    @Environment(AppModel.self) private var model
    let shot: Shot
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            tile(copied ? "Copied" : "Copy", copied ? "checkmark" : "doc.on.doc") {
                model.copyImage(shot)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            }
            tile("Quick Look", "eye") { model.quickLook(shot) }
            tile("Reveal", "folder") { model.revealInFinder(shot) }
            tile("Open", "arrow.up.forward.app") { model.open(shot) }
        }
        .disabled(!shot.fileExists)
    }

    private func tile(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(.rect)
        }
        .buttonStyle(TileButtonStyle())
        .clickable()
    }
}

/// A filled tile that darkens while pressed.
private struct TileButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .background(.quaternary.opacity(configuration.isPressed ? 1 : 0.6), in: .rect(cornerRadius: 8))
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
