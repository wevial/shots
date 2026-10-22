import ShotsKit
import SwiftUI

/// Everything Shots needs from macOS, with live state and a button to fix each item.
struct StatusView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(CapturePreviewController.enabledKey) private var showsCapturePreview = true

    var body: some View {
        Form {
            engineSection
            permissionsSection
            modelSection
            toolsSection
            configSection
            loginSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .task {
            // Permissions change in System Settings, not here, so poll while the window is up.
            while !Task.isCancelled {
                model.loginItem.refresh()
                await model.system.refresh(config: model.daemon.config)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Sections

    private var engineSection: some View {
        Section("Watcher") {
            LabeledContent("Status") {
                HStack(spacing: 8) {
                    Text(model.statusLine)
                    Button(model.daemon.isPaused ? "Resume" : "Pause") {
                        Task { await model.togglePaused() }
                    }
                }
            }
            if case .failed(let message) = model.daemon.state {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
            Toggle("Show Preview After Capture", isOn: $showsCapturePreview)
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        let system = model.system
        Section {
            PermissionRow(
                title: "Accessibility",
                detail: "Reads the focused window's title.",
                granted: system.permissions?.accessibility,
                actionTitle: "Request…",
                action: { system.requestAccessibility() },
                openSettings: { system.openSettings(.accessibility) }
            )
            PermissionRow(
                title: "Screen Recording",
                detail: "Optional; used for window context.",
                granted: system.permissions?.screenRecording,
                actionTitle: nil,
                action: {},
                openSettings: { system.openSettings(.screenRecording) }
            )
            if let automation = system.permissions?.automation, !automation.isEmpty {
                ForEach(automation.keys.sorted(), id: \.self) { bundleID in
                    LabeledContent(bundleID) {
                        HStack(spacing: 8) {
                            Text(Self.automationLabel(automation[bundleID] ?? ""))
                                .foregroundStyle(automation[bundleID] == "granted" ? Color.green : Color.secondary)
                            Button("Open Settings") { system.openSettings(.automation) }
                        }
                    }
                }
            } else {
                LabeledContent("Automation") {
                    Button("Open Settings") { system.openSettings(.automation) }
                }
            }
            if let error = system.permissionsError {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Automation lets Shots read the URL of the active browser tab. macOS asks the first time a browser is in front.")
        }
    }

    private var modelSection: some View {
        Section("Apple Intelligence") {
            if let fm = model.system.fm {
                LabeledContent("On-device model") {
                    Text(fm.available ? "Available" : "Unavailable: \(fm.reason ?? "unknown")")
                        .foregroundStyle(fm.available ? Color.green : Color.orange)
                }
                LabeledContent("Image input") {
                    Text(fm.imageInput.enabled ? "On" : "Off").foregroundStyle(.secondary)
                }
                Text(fm.imageInput.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = model.system.fmError {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var toolsSection: some View {
        Section("Cloud classifiers") {
            ForEach(model.system.tools) { tool in
                LabeledContent(tool.name) {
                    if let path = tool.path {
                        Text(path).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text("Not found").foregroundStyle(.orange)
                    }
                }
                if tool.path != nil {
                    Text(tool.hint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var configSection: some View {
        Section("Config") {
            LabeledContent("File") {
                Text(model.config.configPath).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Reveal in Finder") {
                    model.revealInFinder(URL(filePath: model.config.configPath))
                }
                Button("Reload Config") {
                    Task { await model.reloadConfig() }
                }
            }
        }
    }

    private var loginSection: some View {
        Section {
            Toggle("Launch at Login", isOn: Binding(
                get: { model.loginItem.isOn },
                set: { model.loginItem.setOn($0) }
            ))
            if model.loginItem.needsApproval {
                HStack {
                    Text("Approve Shots in Login Items.").foregroundStyle(.orange)
                    Button("Open Settings") { model.loginItem.openSystemSettings() }
                }
            }
            if let error = model.loginItem.lastError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            Text("Startup")
        }
    }

    private static func automationLabel(_ state: String) -> String {
        switch state {
        case "granted": "Allowed"
        case "denied": "Denied"
        case "not-asked": "Not asked yet"
        case "app-not-running": "App not running"
        default: state
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool?
    let actionTitle: String?
    let action: () -> Void
    let openSettings: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(granted == nil ? "Checking…" : (granted! ? "Granted" : "Not granted"))
                    .foregroundStyle(granted == true ? Color.green : Color.orange)
                if granted != true, let actionTitle {
                    Button(actionTitle, action: action)
                }
                Button("Open Settings", action: openSettings)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    StatusView()
        .environment(AppModel.preview())
}
