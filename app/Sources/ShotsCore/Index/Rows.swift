import Foundation

/// A job's state. `pending → processing → done | failed | skipped`; a failed job under
/// `maxAttempts` goes back to `pending` for its retry, and a `processing` job found at
/// startup (the daemon died mid-job) goes back to `pending` too.
public enum JobStatus: String, Sendable, Codable, CaseIterable {
    case pending, processing, done, failed, skipped
}

/// A row of the `jobs` table: one inbox file the daemon decided to look at.
public struct JobRow: Sendable, Equatable, JSONRepresentable {
    public var id: Int64
    public var inboxPath: String
    public var originalName: String
    public var detectedAt: String
    public var status: JobStatus
    public var attempts: Int
    public var lastError: String?
    /// The `AppContext` captured when the file landed, as JSON.
    public var contextJSON: String?
    public var sha256: String?
    public var shotId: Int64?
    public var updatedAt: String

    /// `contextJSON`, decoded. Nil when there was none or it doesn't parse.
    public var context: AppContext? {
        guard let contextJSON else { return nil }
        return try? JSONDecoder().decode(AppContext.self, from: Data(contextJSON.utf8))
    }

    public init(row: SQLiteConnection.Row) {
        id = row.int("id") ?? 0
        inboxPath = row.string("inbox_path") ?? ""
        originalName = row.string("original_name") ?? ""
        detectedAt = row.string("detected_at") ?? ""
        status = row.string("status").flatMap(JobStatus.init(rawValue:)) ?? .pending
        attempts = Int(row.int("attempts") ?? 0)
        lastError = row.string("last_error")
        contextJSON = row.string("context_json")
        sha256 = row.string("sha256")
        shotId = row.int("shot_id")
        updatedAt = row.string("updated_at") ?? ""
    }

    /// The raw row, with the column names as keys.
    public var json: JSONValue {
        [
            "id": JSONValue(id), "inbox_path": .string(inboxPath), "original_name": .string(originalName),
            "detected_at": .string(detectedAt), "status": .string(status.rawValue), "attempts": JSONValue(attempts),
            "last_error": JSONValue(lastError), "context_json": JSONValue(contextJSON), "sha256": JSONValue(sha256),
            "shot_id": JSONValue(shotId), "updated_at": .string(updatedAt),
        ]
    }
}

/// A row of the `shots` table: one filed screenshot. Values are kept as stored (dates as
/// ISO strings, tags as JSON text) so writing a row back never changes it.
public struct ShotRow: Sendable, Equatable, Hashable, JSONRepresentable {
    public var id: Int64
    public var path: String
    public var originalName: String
    public var sha256: String
    public var capturedAt: String
    public var processedAt: String
    public var appBundleId: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?
    public var urlTitle: String?
    public var captureType: String?
    public var width: Int?
    public var height: Int?
    public var ocrText: String
    public var category: String
    /// The model's own category when the shot was parked in misc for review.
    public var suggestedCategory: String?
    /// A JSON array of strings.
    public var tagsJSON: String
    /// The tags joined with spaces, for full-text search.
    public var tagsText: String
    public var title: String
    public var confidence: Double
    /// `apple`, `claude-code`, `codex`, `rules` or `manual`.
    public var backend: String
    public var review: Bool
    /// The chain's attempts as JSON (`[Attempt]`).
    public var attemptsJSON: String?
    /// The classifier's scratch verdict; nil for shots filed before it gave one.
    public var scratch: Bool?
    /// You chose to keep it, so Clean Up never suggests it.
    public var kept: Bool

    public var tags: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []
    }

    public var capturedDate: Date? { Timestamp.parse(capturedAt) }

    public init(row: SQLiteConnection.Row) {
        id = row.int("id") ?? 0
        path = row.string("path") ?? ""
        originalName = row.string("original_name") ?? ""
        sha256 = row.string("sha256") ?? ""
        capturedAt = row.string("captured_at") ?? ""
        processedAt = row.string("processed_at") ?? ""
        appBundleId = row.string("app_bundle_id")
        appName = row.string("app_name")
        windowTitle = row.string("window_title")
        url = row.string("url")
        urlTitle = row.string("url_title")
        captureType = row.string("capture_type")
        width = row.int("width").map(Int.init)
        height = row.int("height").map(Int.init)
        ocrText = row.string("ocr_text") ?? ""
        category = row.string("category") ?? "misc"
        suggestedCategory = row.string("suggested_category")
        tagsJSON = row.string("tags_json") ?? "[]"
        tagsText = row.string("tags_text") ?? ""
        title = row.string("title") ?? ""
        confidence = row.double("confidence") ?? 0
        backend = row.string("backend") ?? ""
        review = (row.int("review") ?? 0) != 0
        attemptsJSON = row.string("attempts_json")
        scratch = row.int("scratch").map { $0 != 0 }
        kept = (row.int("kept") ?? 0) != 0
    }

    /// The raw row with the column names as keys, in column order: what `shots recat --json`
    /// prints under `shot`, and what the viewer decodes.
    public var json: JSONValue {
        .object(jsonObject)
    }

    /// `json` as an object, for callers that add or drop keys (`search --json` drops ocr_text).
    public var jsonObject: JSONObject {
        [
            "id": JSONValue(id), "path": .string(path), "original_name": .string(originalName), "sha256": .string(sha256),
            "captured_at": .string(capturedAt), "processed_at": .string(processedAt),
            "app_bundle_id": JSONValue(appBundleId), "app_name": JSONValue(appName), "window_title": JSONValue(windowTitle),
            "url": JSONValue(url), "url_title": JSONValue(urlTitle), "capture_type": JSONValue(captureType),
            "width": JSONValue(width), "height": JSONValue(height), "ocr_text": .string(ocrText),
            "category": .string(category), "suggested_category": JSONValue(suggestedCategory),
            "tags_json": .string(tagsJSON), "tags_text": .string(tagsText), "title": .string(title),
            "confidence": .number(confidence), "backend": .string(backend), "review": review ? 1 : 0,
            "attempts_json": JSONValue(attemptsJSON), "scratch": JSONValue(scratch.map { $0 ? 1 : 0 }), "kept": kept ? 1 : 0,
        ]
    }
}

/// What the pipeline inserts. `id` and `tags_text` come from the database.
public struct NewShot: Sendable, Equatable {
    public var path: String
    public var originalName: String
    public var sha256: String
    public var capturedAt: String
    public var processedAt: String
    public var appBundleId: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?
    public var urlTitle: String?
    public var captureType: String?
    public var width: Int?
    public var height: Int?
    public var ocrText: String
    public var category: String
    public var suggestedCategory: String?
    public var tags: [String]
    public var title: String
    public var confidence: Double
    public var backend: String
    public var review: Bool
    public var attemptsJSON: String?
    public var scratch: Bool?

    public init(
        path: String, originalName: String, sha256: String, capturedAt: String, processedAt: String,
        appBundleId: String? = nil, appName: String? = nil, windowTitle: String? = nil, url: String? = nil,
        urlTitle: String? = nil, captureType: String? = nil, width: Int? = nil, height: Int? = nil,
        ocrText: String = "", category: String, suggestedCategory: String? = nil, tags: [String] = [],
        title: String, confidence: Double, backend: String, review: Bool = false, attemptsJSON: String? = nil,
        scratch: Bool? = nil
    ) {
        self.path = path
        self.originalName = originalName
        self.sha256 = sha256
        self.capturedAt = capturedAt
        self.processedAt = processedAt
        self.appBundleId = appBundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.urlTitle = urlTitle
        self.captureType = captureType
        self.width = width
        self.height = height
        self.ocrText = ocrText
        self.category = category
        self.suggestedCategory = suggestedCategory
        self.tags = tags
        self.title = title
        self.confidence = confidence
        self.backend = backend
        self.review = review
        self.attemptsJSON = attemptsJSON
        self.scratch = scratch
    }
}

/// What `recat` changes on a shot.
public struct ShotUpdate: Sendable, Equatable {
    public var path: String
    public var category: String
    public var suggestedCategory: String?
    public var tags: [String]
    public var title: String
    public var confidence: Double
    public var backend: String
    public var review: Bool
    public var attemptsJSON: String?
    public var processedAt: String
    public var scratch: Bool?

    public init(
        path: String, category: String, suggestedCategory: String?, tags: [String], title: String,
        confidence: Double, backend: String, review: Bool, attemptsJSON: String?, processedAt: String = Timestamp.now(),
        scratch: Bool? = nil
    ) {
        self.path = path
        self.category = category
        self.suggestedCategory = suggestedCategory
        self.tags = tags
        self.title = title
        self.confidence = confidence
        self.backend = backend
        self.review = review
        self.attemptsJSON = attemptsJSON
        self.processedAt = processedAt
        self.scratch = scratch
    }
}

/// A search result: the row plus an FTS snippet of the OCR text with `[`…`]` around hits.
public struct SearchHit: Sendable, Equatable {
    public var shot: ShotRow
    public var snippet: String
}

/// Counts for `shots doctor`.
public struct IndexStats: Sendable, Equatable {
    public struct BackendCount: Sendable, Equatable {
        public var backend: String
        public var count: Int
    }

    /// Job status → count.
    public var jobs: [String: Int]
    public var shots: Int
    public var review: Int
    public var byBackend: [BackendCount]
}

/// `tags_json` text for a tag list, as `JSON.stringify` writes it.
func tagsJSON(_ tags: [String]) -> String { JSONValue(tags).serialized() }
