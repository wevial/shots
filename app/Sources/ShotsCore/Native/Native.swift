import Foundation

/// Everything the pipeline needs from macOS. `SystemNative` (in ShotsNative) is the real
/// one; tests pass a fake.
///
/// Implementations are free to hop to the main actor where an API needs it (NSAppleScript,
/// NSPasteboard). Methods throw for broken calls (unreadable file, failed xattr write);
/// "nothing to report" is a nil or empty value instead.
public protocol Native: Sendable {
    /// Screenshot xattrs (`com.apple.metadata:kMDItemIsScreenCapture` / `…ScreenCaptureType`),
    /// falling back to `mdls` when the file has none.
    func meta(_ path: String) async throws -> ScreenshotMeta

    /// The frontmost app, its focused window title and, for browsers, the active tab.
    /// Called the moment a file lands, before anything slow.
    func context() async throws -> AppContext?

    /// Vision text recognition. Empty `languages` means detect automatically.
    func ocr(_ path: String, languages: [String]) async throws -> OcrResult

    func fmStatus() async throws -> FmStatus

    /// One Foundation Models request, in process. The image goes along only on macOS 27+
    /// with a model that has the vision capability; otherwise the request is text-only.
    /// Never throws: every failure is a response case the apple backend maps to an outcome.
    func fmClassify(instructions: String, prompt: String, imagePath: String, timeout: Duration) async -> FmClassifyResponse

    /// Merges `tags` into the file's Finder tags after dropping `remove` (tags shots applied
    /// earlier), keeping any tags the user added themselves.
    func setTags(_ path: String, _ tags: [String], remove: [String]) async throws

    func copyToClipboard(_ path: String) async throws

    func permissions() async throws -> Permissions
}

extension Native {
    public func setTags(_ path: String, _ tags: [String]) async throws {
        try await setTags(path, tags, remove: [])
    }
}

/// What was in front when a screenshot landed. Stored as `jobs.context_json`, with the key
/// names and explicit nulls the TypeScript daemon wrote.
public struct AppContext: Sendable, Equatable, Codable, JSONRepresentable {
    public var bundleId: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?
    public var urlTitle: String?
    /// ISO 8601, see `Timestamp`.
    public var capturedAt: String
    public var accessibility: Bool
    public var notes: [String]

    public init(
        bundleId: String? = nil, appName: String? = nil, windowTitle: String? = nil, url: String? = nil,
        urlTitle: String? = nil, capturedAt: String = Timestamp.now(), accessibility: Bool = false, notes: [String] = []
    ) {
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.urlTitle = urlTitle
        self.capturedAt = capturedAt
        self.accessibility = accessibility
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleId: try c.decodeIfPresent(String.self, forKey: .bundleId),
            appName: try c.decodeIfPresent(String.self, forKey: .appName),
            windowTitle: try c.decodeIfPresent(String.self, forKey: .windowTitle),
            url: try c.decodeIfPresent(String.self, forKey: .url),
            urlTitle: try c.decodeIfPresent(String.self, forKey: .urlTitle),
            capturedAt: try c.decodeIfPresent(String.self, forKey: .capturedAt) ?? "",
            accessibility: try c.decodeIfPresent(Bool.self, forKey: .accessibility) ?? false,
            notes: try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        )
    }

    public var json: JSONValue {
        [
            "bundleId": JSONValue(bundleId), "appName": JSONValue(appName), "windowTitle": JSONValue(windowTitle),
            "url": JSONValue(url), "urlTitle": JSONValue(urlTitle), "capturedAt": .string(capturedAt),
            "accessibility": .bool(accessibility), "notes": JSONValue(notes),
        ]
    }
}

public struct ScreenshotMeta: Sendable, Equatable {
    public enum Source: String, Sendable { case xattr, mdls, none }

    /// Nil when nothing says either way (no xattrs, Spotlight hasn't indexed it).
    public var isScreenCapture: Bool?
    /// `selection`, `window` or `display`.
    public var captureType: String?
    public var source: Source

    public init(isScreenCapture: Bool?, captureType: String?, source: Source) {
        self.isScreenCapture = isScreenCapture
        self.captureType = captureType
        self.source = source
    }
}

public struct OcrResult: Sendable, Equatable {
    /// Lines in reading order (top to bottom, then left to right), joined with newlines.
    public var text: String
    public var width: Int
    public var height: Int

    public init(text: String, width: Int, height: Int) {
        self.text = text
        self.width = width
        self.height = height
    }
}

/// Whether Foundation Models can run here. The shape `shots-helper fm-status` printed.
public struct FmStatus: Sendable, Equatable, Codable, JSONRepresentable {
    public struct ImageInput: Sendable, Equatable, Codable {
        public var enabled: Bool
        public var reason: String
        public init(enabled: Bool, reason: String) {
            self.enabled = enabled
            self.reason = reason
        }
    }

    public var osVersion: String
    public var available: Bool
    /// Why it's unavailable (`appleIntelligenceNotEnabled`, `modelNotReady`, …).
    public var reason: String?
    public var imageInput: ImageInput
    public var contextSize: Int?
    public var localeSupported: Bool?

    public init(osVersion: String, available: Bool, reason: String? = nil, imageInput: ImageInput, contextSize: Int? = nil, localeSupported: Bool? = nil) {
        self.osVersion = osVersion
        self.available = available
        self.reason = reason
        self.imageInput = imageInput
        self.contextSize = contextSize
        self.localeSupported = localeSupported
    }

    public var json: JSONValue {
        var object: JSONObject = [
            "osVersion": .string(osVersion), "available": .bool(available),
            "imageInput": ["enabled": .bool(imageInput.enabled), "reason": .string(imageInput.reason)],
        ]
        if let localeSupported { object["localeSupported"] = .bool(localeSupported) }
        if let reason { object["reason"] = .string(reason) }
        if let contextSize { object["contextSize"] = JSONValue(contextSize) }
        return .object(object)
    }
}

public enum FmClassifyResponse: Sendable, Equatable {
    /// The model's answer as it gave it; the apple backend validates and normalizes it.
    /// `mode` is `text` or `multimodal`.
    case ok(ClassifyResult, mode: String)
    /// The model can't run (`SystemLanguageModel.Availability` reason).
    case unavailable(reason: String)
    /// The request took longer than its timeout and was cancelled.
    case timedOut
    /// Generation failed. Errors are named the way shots-helper named them
    /// (`exceededContextWindowSize`, `guardrailViolation`, …); the apple backend retries
    /// once with less OCR when the message contains `exceededContextWindowSize`.
    case error(message: String)
}

/// TCC state as this process sees it.
public struct Permissions: Sendable, Equatable, Codable, JSONRepresentable {
    public var accessibility: Bool
    public var screenRecording: Bool
    /// Browser bundle ID → `granted` / `denied` / `not-asked` / `app-not-running` / `unknown(…)`.
    public var automation: [String: String]

    public init(accessibility: Bool, screenRecording: Bool, automation: [String: String] = [:]) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.automation = automation
    }

    public var json: JSONValue {
        ["accessibility": .bool(accessibility), "screenRecording": .bool(screenRecording), "automation": JSONValue(automation)]
    }
}
