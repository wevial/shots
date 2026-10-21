import AppKit
import ApplicationServices
import CoreGraphics

private let safariFamily: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
private let chromiumFamily: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
    "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    "org.chromium.Chromium", "company.thebrowser.Browser", "company.thebrowser.dia",
]
private let axBrowsers: Set<String> = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen"]

func axCopy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
}

/// Depth-limited search for the first AXWebArea; browsers expose the page URL there.
private func findWebArea(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if depth > 12 { return nil }
    if (axCopy(el, kAXRoleAttribute) as? String) == "AXWebArea" { return el }
    guard let children = axCopy(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for child in children {
        if let found = findWebArea(child, depth: depth + 1) { return found }
    }
    return nil
}

/// Window title without Accessibility: CGWindowList names need Screen Recording, so this is a fallback.
private func cgWindowTitle(pid: pid_t) -> String? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        if let name = w[kCGWindowName as String] as? String, !name.isEmpty { return name }
    }
    return nil
}

private func appleScriptBrowserTab(bundleId: String) -> (url: String, title: String)? {
    let source: String
    if safariFamily.contains(bundleId) {
        source = "tell application id \"\(bundleId)\" to get {URL, name} of current tab of front window"
    } else if chromiumFamily.contains(bundleId) {
        source = "tell application id \"\(bundleId)\" to get {URL, title} of active tab of front window"
    } else {
        return nil
    }
    var err: NSDictionary?
    guard let result = NSAppleScript(source: source)?.executeAndReturnError(&err), err == nil,
          result.numberOfItems == 2,
          let url = result.atIndex(1)?.stringValue else { return nil }
    return (url, result.atIndex(2)?.stringValue ?? "")
}

func isBrowser(_ bundleId: String) -> Bool {
    safariFamily.contains(bundleId) || chromiumFamily.contains(bundleId) || axBrowsers.contains(bundleId)
}

func captureContext() -> [String: Any] {
    var out: [String: Any] = ["capturedAt": ISO8601DateFormatter().string(from: Date())]
    var notes: [String] = []
    let trusted = AXIsProcessTrusted()
    out["accessibility"] = trusted

    guard let app = NSWorkspace.shared.frontmostApplication else {
        out["notes"] = ["no frontmost application"]
        return out
    }
    let bundleId = app.bundleIdentifier ?? ""
    out["app"] = ["bundleId": bundleId, "name": app.localizedName ?? "", "pid": Int(app.processIdentifier)]

    var windowTitle: String?
    var axURL: String?
    var axPageTitle: String?
    if trusted {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium builds its AX tree lazily; this asks it to expose web content.
        if chromiumFamily.contains(bundleId) {
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        if let window = axCopy(axApp, kAXFocusedWindowAttribute) {
            let win = window as! AXUIElement
            windowTitle = axCopy(win, kAXTitleAttribute) as? String
            if isBrowser(bundleId) {
                if let doc = axCopy(win, kAXDocumentAttribute) as? String { axURL = doc }
                if let area = findWebArea(win) {
                    if let u = axCopy(area, "AXURL") { axURL = (u as? URL)?.absoluteString ?? (u as? String) ?? axURL }
                    axPageTitle = axCopy(area, kAXTitleAttribute) as? String ?? axCopy(area, kAXDescriptionAttribute) as? String
                }
            }
        } else {
            notes.append("no focused window via AX")
        }
    } else {
        notes.append("accessibility not granted; window title from CGWindowList if Screen Recording is granted")
        windowTitle = cgWindowTitle(pid: app.processIdentifier)
    }
    if let t = windowTitle, !t.isEmpty { out["windowTitle"] = t }

    if isBrowser(bundleId) {
        if let tab = appleScriptBrowserTab(bundleId: bundleId) {
            out["browser"] = ["url": tab.url, "title": tab.title, "source": "applescript"]
        } else if let u = axURL {
            out["browser"] = ["url": u, "title": axPageTitle ?? windowTitle ?? "", "source": "ax"]
        } else {
            notes.append("browser tab unavailable (Automation or Accessibility not granted)")
        }
    }
    if !notes.isEmpty { out["notes"] = notes }
    return out
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

func permissionStatus() -> [String: Any] {
    var automation: [String: String] = [:]
    for app in NSWorkspace.shared.runningApplications {
        if let id = app.bundleIdentifier, safariFamily.contains(id) || chromiumFamily.contains(id) {
            automation[id] = automationStatus(bundleId: id)
        }
    }
    return [
        "accessibility": AXIsProcessTrusted(),
        "screenRecording": CGPreflightScreenCaptureAccess(),
        "automation": automation,
    ]
}
