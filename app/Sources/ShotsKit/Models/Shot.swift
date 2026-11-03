import Foundation
import ShotsCore

/// One filed screenshot: a row of the `shots` table.
public struct Shot: Identifiable, Hashable, Sendable {
    public var id: Int64
    /// Absolute path of the file today. `recat` moves files, so this changes.
    public var path: String
    public var originalName: String
    public var sha256: String
    public var capturedAt: Date
    public var processedAt: Date
    public var appBundleID: String?
    public var appName: String?
    public var windowTitle: String?
    /// The browser tab's URL when the screenshot was taken (the `url` column).
    public var pageURL: URL?
    /// The browser tab's title (the `url_title` column).
    public var pageTitle: String?
    /// `selection`, `window` or `display`.
    public var captureType: String?
    public var width: Int?
    public var height: Int?
    public var ocrText: String
    public var category: String
    /// What the model actually said when the shot was parked in `misc` for review.
    public var suggestedCategory: String?
    public var tags: [String]
    public var title: String
    public var confidence: Double
    /// Raw backend name (`apple`, `claude-code`, `codex`, `rules`, `manual`).
    public var backend: String
    public var needsReview: Bool
    /// The classifier thinks it's a throwaway and you haven't chosen to keep it.
    public var isScratch: Bool

    public init(
        id: Int64,
        path: String,
        originalName: String,
        sha256: String = "",
        capturedAt: Date,
        processedAt: Date,
        appBundleID: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        pageURL: URL? = nil,
        pageTitle: String? = nil,
        captureType: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        ocrText: String = "",
        category: String,
        suggestedCategory: String? = nil,
        tags: [String] = [],
        title: String,
        confidence: Double,
        backend: String,
        needsReview: Bool = false,
        isScratch: Bool = false
    ) {
        self.id = id
        self.path = path
        self.originalName = originalName
        self.sha256 = sha256
        self.capturedAt = capturedAt
        self.processedAt = processedAt
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.pageURL = pageURL
        self.pageTitle = pageTitle
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
        self.needsReview = needsReview
        self.isScratch = isScratch
    }
}

// MARK: - Conveniences for views

extension Shot {
    public var fileURL: URL { URL(filePath: path) }
    public var fileName: String { fileURL.lastPathComponent }

    /// False when the file was moved or removed outside the app.
    public var fileExists: Bool { FileManager.default.fileExists(atPath: path) }

    public var classifierBackend: ClassifierBackend? { ClassifierBackend(rawValue: backend) }

    /// "1920 × 1080", or nil when the size wasn't recorded.
    public var pixelSize: String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    public var displayTitle: String { title.isEmpty ? fileName : title }
}

// MARK: - Decoding the CLI's JSON (`shots recat --json` prints a raw `shots` row)

extension Shot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, path, sha256, width, height, category, title, confidence, backend, review, url, scratch, kept
        case originalName = "original_name"
        case capturedAt = "captured_at"
        case processedAt = "processed_at"
        case appBundleID = "app_bundle_id"
        case appName = "app_name"
        case windowTitle = "window_title"
        case urlTitle = "url_title"
        case captureType = "capture_type"
        case ocrText = "ocr_text"
        case suggestedCategory = "suggested_category"
        case tagsJSON = "tags_json"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ key: CodingKeys) throws -> Date {
            let text = try c.decode(String.self, forKey: key)
            guard let date = ISODate.parse(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }

        self.init(
            id: try c.decode(Int64.self, forKey: .id),
            path: try c.decode(String.self, forKey: .path),
            originalName: try c.decode(String.self, forKey: .originalName),
            sha256: try c.decodeIfPresent(String.self, forKey: .sha256) ?? "",
            capturedAt: try date(.capturedAt),
            processedAt: try date(.processedAt),
            appBundleID: try c.decodeIfPresent(String.self, forKey: .appBundleID),
            appName: try c.decodeIfPresent(String.self, forKey: .appName),
            windowTitle: try c.decodeIfPresent(String.self, forKey: .windowTitle),
            pageURL: try c.decodeIfPresent(String.self, forKey: .url).flatMap(URL.init(string:)),
            pageTitle: try c.decodeIfPresent(String.self, forKey: .urlTitle),
            captureType: try c.decodeIfPresent(String.self, forKey: .captureType),
            width: try c.decodeIfPresent(Int.self, forKey: .width),
            height: try c.decodeIfPresent(Int.self, forKey: .height),
            ocrText: try c.decodeIfPresent(String.self, forKey: .ocrText) ?? "",
            category: try c.decode(String.self, forKey: .category),
            suggestedCategory: try c.decodeIfPresent(String.self, forKey: .suggestedCategory),
            tags: Shot.decodeTags(try c.decodeIfPresent(String.self, forKey: .tagsJSON)),
            title: try c.decode(String.self, forKey: .title),
            confidence: try c.decode(Double.self, forKey: .confidence),
            backend: try c.decode(String.self, forKey: .backend),
            needsReview: (try c.decodeIfPresent(Int.self, forKey: .review) ?? 0) != 0,
            isScratch: try (c.decodeIfPresent(Int.self, forKey: .scratch) ?? 0) != 0
                && (c.decodeIfPresent(Int.self, forKey: .kept) ?? 0) == 0
        )
    }

    /// `tags_json` is a JSON array stored as text. Bad or missing JSON means no tags.
    static func decodeTags(_ json: String?) -> [String] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

/// The daemon writes `Date.toISOString()` (always with milliseconds), but accept both forms.
enum ISODate {
    static func parse(_ text: String) -> Date? { Timestamp.parse(text) }
}

// MARK: - From the index's own rows

extension Shot {
    /// The viewer's model of a `shots` row. Unparseable dates become `.distantPast`.
    public init(row: ShotRow) {
        self.init(
            id: row.id,
            path: row.path,
            originalName: row.originalName,
            sha256: row.sha256,
            capturedAt: ISODate.parse(row.capturedAt) ?? .distantPast,
            processedAt: ISODate.parse(row.processedAt) ?? .distantPast,
            appBundleID: row.appBundleId,
            appName: row.appName,
            windowTitle: row.windowTitle,
            pageURL: row.url.flatMap(URL.init(string:)),
            pageTitle: row.urlTitle,
            captureType: row.captureType,
            width: row.width,
            height: row.height,
            ocrText: row.ocrText,
            category: row.category,
            suggestedCategory: row.suggestedCategory,
            tags: row.tags,
            title: row.title,
            confidence: row.confidence,
            backend: row.backend,
            needsReview: row.review,
            isScratch: row.scratch == true && !row.kept
        )
    }
}
