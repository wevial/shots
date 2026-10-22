import AppKit
import ApplicationServices
import Observation
import ShotsCore

/// What the status window shows: permissions, Foundation Models, and the CLI classifiers.
@MainActor
@Observable
public final class SystemStatus {
    public struct Tool: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public var name: String
        public var path: String?
        public var hint: String
    }

    public private(set) var permissions: Permissions?
    public private(set) var permissionsError: String?
    public private(set) var fm: FmStatus?
    public private(set) var fmError: String?
    public private(set) var tools: [Tool] = []

    @ObservationIgnored private let native: any Native

    public init(native: any Native) {
        self.native = native
    }

    /// Re-reads everything. Cheap enough to call every couple of seconds while the window is up.
    public func refresh(config: Config?) async {
        do {
            permissions = try await native.permissions()
            permissionsError = nil
        } catch {
            permissionsError = errorMessage(error)
        }
        do {
            fm = try await native.fmStatus()
            fmError = nil
        } catch {
            fmError = errorMessage(error)
        }
        if let config {
            tools = [
                Tool(name: "Claude Code", path: Exec.which(config.claudeCode.binary), hint: "Run `\(config.claudeCode.binary)` once in Terminal to sign in."),
                Tool(name: "Codex", path: Exec.which(config.codex.binary), hint: "Run `\(config.codex.binary) login` in Terminal to sign in."),
            ]
        }
    }

    // MARK: Opening the right place

    public enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case automation = "Privacy_Automation"
    }

    public func openSettings(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    /// Shows the system's Accessibility prompt (which also adds Shots to the list).
    public func requestAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt, spelled out to stay clear of a global var.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
