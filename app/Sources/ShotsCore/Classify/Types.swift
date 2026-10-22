import Foundation

/// What every backend gets to look at for one screenshot.
public struct ClassifyInput: Sendable, Equatable {
    public struct Dimensions: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public var imagePath: String
    public var ocrText: String
    public var appContext: AppContext?
    public var captureType: String?
    public var dimensions: Dimensions?
    public var categories: [String]
    public var categoryHints: [String: String]

    public init(
        imagePath: String, ocrText: String, appContext: AppContext?, captureType: String?,
        dimensions: Dimensions?, categories: [String], categoryHints: [String: String] = [:]
    ) {
        self.imagePath = imagePath
        self.ocrText = ocrText
        self.appContext = appContext
        self.captureType = captureType
        self.dimensions = dimensions
        self.categories = categories
        self.categoryHints = categoryHints
    }
}

/// A backend's answer. After `validateResult`, the category is trimmed and lowercased and
/// the tags are normalized; it may still name a category outside the config (the chain
/// turns that into misc + review).
public struct ClassifyResult: Sendable, Equatable, Hashable, Codable, JSONRepresentable {
    public var category: String
    public var tags: [String]
    public var title: String
    public var confidence: Double

    public init(category: String, tags: [String], title: String, confidence: Double) {
        self.category = category
        self.tags = tags
        self.title = title
        self.confidence = confidence
    }

    public var json: JSONValue {
        ["category": .string(category), "tags": JSONValue(tags), "title": .string(title), "confidence": .number(confidence)]
    }
}

/// Why a backend produced no result.
public enum FailureKind: String, Sendable, Codable {
    /// Not installed, not signed in, model not ready.
    case unavailable
    case error
    case timeout
    /// It answered, but not with a usable result (even after the corrective retry).
    case invalid
    /// The chain didn't call it because privacy rules keep this shot on the machine.
    /// Only the chain records this; backends never return it.
    case skipped
}

public enum ClassifyOutcome: Sendable, Equatable {
    /// `detail` notes how the result came about (`after-retry`, `multimodal`, `capped from 0.9`).
    case success(ClassifyResult, detail: String? = nil)
    case failure(FailureKind, message: String)

    public var result: ClassifyResult? {
        if case .success(let result, _) = self { result } else { nil }
    }

    public var isSuccess: Bool { result != nil }
}

extension ClassifyOutcome: JSONRepresentable {
    /// `{ok: true, result, detail?}` or `{ok: false, kind, message}`, as in `attempts_json`.
    public var json: JSONValue {
        switch self {
        case .success(let result, let detail):
            var object: JSONObject = ["ok": true, "result": result.json]
            if let detail { object["detail"] = .string(detail) }
            return .object(object)
        case .failure(let kind, let message):
            return ["ok": false, "kind": .string(kind.rawValue), "message": .string(message)]
        }
    }
}

/// One classifier. Backends are values: build them once from the config and reuse them.
public protocol Backend: Sendable {
    /// `apple`, `claude-code`, `codex`, `rules`; what ends up in `shots.backend`.
    var name: String { get }
    /// Cloud backends send content off the machine and obey allowCloud and the denylists.
    var isCloud: Bool { get }
    /// Report failures as `.failure`. A thrown error is recorded as an `error` outcome.
    func classify(_ input: ClassifyInput) async throws -> ClassifyOutcome
}
