import AppKit
import ApplicationServices
import CoreGraphics
import ShotsCore

private let safariFamily: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
private let chromiumFamily: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
    "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    "org.chromium.Chromium", "company.thebrowser.Browser", "company.thebrowser.dia",
]
private let axBrowsers: Set<String> = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen"]

private func isBrowser(_ bundleId: String) -> Bool {
    safariFamily.contains(bundleId) || chromiumFamily.contains(bundleId) || axBrowsers.contains(bundleId)
}

private func axCopy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

/// Depth-limited search for the first AXWebArea; browsers expose the page URL there.
private func findWebArea(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if depth > 12 { return nil }
    if (axCopy(element, kAXRoleAttribute) as? String) == "AXWebArea" { return element }
    guard let children = axCopy(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for child in children {
        if let found = findWebArea(child, depth: depth + 1) { return found }
    }
    return nil
}

/// Window title without Accessibility. CGWindowList names need Screen Recording, so this is a fallback.
private func cgWindowTitle(pid: pid_t) -> String? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for window in list where (window[kCGWindowOwnerPID as String] as? pid_t) == pid && (window[kCGWindowLayer as String] as? Int) == 0 {
        if let name = window[kCGWindowName as String] as? String, !name.isEmpty { return name }
    }
    return nil
}

/// Safari and Chromium browsers answer AppleScript with the active tab's URL and title.
/// NSAppleScript is not thread-safe, so this runs on the main actor.
@MainActor
private func appleScriptBrowserTab(bundleId: String) -> (url: String, title: String)? {
    let command: String
    if safariFamily.contains(bundleId) {
        command = "tell application id \"\(bundleId)\" to get {URL, name} of current tab of front window"
    } else if chromiumFamily.contains(bundleId) {
        command = "tell application id \"\(bundleId)\" to get {URL, title} of active tab of front window"
    } else {
        return nil
    }
    // This blocks the main thread until the browser answers; Apple events wait two minutes
    // by default. shots-helper ran in its own process and was killed after 5 s instead.
    let source = "with timeout of 3 seconds\n\(command)\nend timeout"
    var error: NSDictionary?
    guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil,
          result.numberOfItems == 2,
          let url = result.atIndex(1)?.stringValue else { return nil }
    return (url, result.atIndex(2)?.stringValue ?? "")
}

/// What the Accessibility API (or CGWindowList) says about the frontmost app. Synchronous
/// and off the main actor; AX calls can block on an unresponsive app.
private struct FrontApp: Sendable {
    var bundleId: String
    var name: String
    var windowTitle: String?
    var axURL: String?
    var axPageTitle: String?
    var trusted: Bool
    var notes: [String]
}

private func inspectFrontmostApp() -> FrontApp? {
    let trusted = AXIsProcessTrusted()
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    var front = FrontApp(
        bundleId: app.bundleIdentifier ?? "", name: app.localizedName ?? "", trusted: trusted, notes: [])
    guard trusted else {
        front.notes.append("accessibility not granted; window title from CGWindowList if Screen Recording is granted")
        front.windowTitle = cgWindowTitle(pid: app.processIdentifier)
        return front
    }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    // Chromium builds its AX tree lazily; this asks it to expose web content.
    if chromiumFamily.contains(front.bundleId) {
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
    guard let window = axCopy(axApp, kAXFocusedWindowAttribute) else {
        front.notes.append("no focused window via AX")
        return front
    }
    let win = window as! AXUIElement
    front.windowTitle = axCopy(win, kAXTitleAttribute) as? String
    if isBrowser(front.bundleId) {
        if let doc = axCopy(win, kAXDocumentAttribute) as? String { front.axURL = doc }
        if let area = findWebArea(win) {
            if let u = axCopy(area, "AXURL") { front.axURL = (u as? URL)?.absoluteString ?? (u as? String) ?? front.axURL }
            front.axPageTitle = axCopy(area, kAXTitleAttribute) as? String ?? axCopy(area, kAXDescriptionAttribute) as? String
        }
    }
    return front
}

func captureAppContext() async -> AppContext? {
    let front = await Task.detached { inspectFrontmostApp() }.value
    guard var front else {
        return AppContext(accessibility: AXIsProcessTrusted(), notes: ["no frontmost application"])
    }
    var context = AppContext(
        bundleId: front.bundleId.isEmpty ? nil : front.bundleId,
        appName: front.name.isEmpty ? nil : front.name,
        windowTitle: (front.windowTitle?.isEmpty ?? true) ? nil : front.windowTitle,
        accessibility: front.trusted)
    if isBrowser(front.bundleId) {
        if let tab = await MainActor.run(body: { appleScriptBrowserTab(bundleId: front.bundleId) }) {
            context.url = tab.url.isEmpty ? nil : tab.url
            context.urlTitle = tab.title.isEmpty ? nil : tab.title
        } else if let url = front.axURL {
            context.url = url.isEmpty ? nil : url
            let title = front.axPageTitle ?? front.windowTitle ?? ""
            context.urlTitle = title.isEmpty ? nil : title
        } else {
            front.notes.append("browser tab unavailable (Automation or Accessibility not granted)")
        }
    }
    context.notes = front.notes
    return context
}

/// Automation status for one target app without triggering the consent prompt.
private func automationStatus(bundleId: String) -> String {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
    let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
    switch status {
    case noErr: return "granted"
    case OSStatus(errAEEventNotPermitted): return "denied"
    case OSStatus(errAEEventWouldRequireUserConsent): return "not-asked"
    case OSStatus(procNotFound): return "app-not-running"
    default: return "unknown(\(status))"
    }
}

func currentPermissions() -> Permissions {
    var automation: [String: String] = [:]
    for app in NSWorkspace.shared.runningApplications {
        if let id = app.bundleIdentifier, safariFamily.contains(id) || chromiumFamily.contains(id) {
            automation[id] = automationStatus(bundleId: id)
        }
    }
    return Permissions(
        accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess(), automation: automation)
}
