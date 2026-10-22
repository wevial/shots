import Foundation
import Observation
import ServiceManagement

/// Start-at-login through `SMAppService.mainApp`. Nothing registers automatically: the user
/// turns it on from the menu bar, the status window, or the first-launch banner.
@MainActor
@Observable
public final class LaunchAtLogin {
    public private(set) var status: SMAppService.Status
    /// The last register/unregister failure, for display.
    public private(set) var lastError: String?
    /// Whether the first-launch banner has been dealt with (accepted or dismissed).
    public private(set) var wasOffered: Bool

    @ObservationIgnored private let defaults: UserDefaults
    private static let offeredKey = "launchAtLoginOffered"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        status = SMAppService.mainApp.status
        wasOffered = defaults.bool(forKey: Self.offeredKey)
    }

    /// On, or registered but waiting for approval in System Settings.
    public var isOn: Bool { status == .enabled || status == .requiresApproval }
    public var needsApproval: Bool { status == .requiresApproval }

    public func refresh() {
        status = SMAppService.mainApp.status
    }

    public func setOn(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        markOffered()
    }

    public func markOffered() {
        wasOffered = true
        defaults.set(true, forKey: Self.offeredKey)
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
