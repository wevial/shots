import Foundation
import ShotsCore

/// A screenshot every backend failed on. It is still in the inbox and the daemon retries it.
/// A row of the `jobs` table with `status = 'failed'`.
public struct FailedJob: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var inboxPath: String
    public var originalName: String
    public var detectedAt: Date
    public var attempts: Int
    public var lastError: String?
    public var updatedAt: Date

    public init(
        id: Int64,
        inboxPath: String,
        originalName: String,
        detectedAt: Date,
        attempts: Int,
        lastError: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.inboxPath = inboxPath
        self.originalName = originalName
        self.detectedAt = detectedAt
        self.attempts = attempts
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    public var fileURL: URL { URL(filePath: inboxPath) }
    public var fileName: String { fileURL.lastPathComponent }
    public var fileExists: Bool { FileManager.default.fileExists(atPath: inboxPath) }
}

extension FailedJob: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, attempts
        case inboxPath = "inbox_path"
        case originalName = "original_name"
        case detectedAt = "detected_at"
        case lastError = "last_error"
        case updatedAt = "updated_at"
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
            inboxPath: try c.decode(String.self, forKey: .inboxPath),
            originalName: try c.decode(String.self, forKey: .originalName),
            detectedAt: try date(.detectedAt),
            attempts: try c.decode(Int.self, forKey: .attempts),
            lastError: try c.decodeIfPresent(String.self, forKey: .lastError),
            updatedAt: try date(.updatedAt)
        )
    }
}

extension FailedJob {
    public init(row: JobRow) {
        self.init(
            id: row.id,
            inboxPath: row.inboxPath,
            originalName: row.originalName,
            detectedAt: ISODate.parse(row.detectedAt) ?? .distantPast,
            attempts: row.attempts,
            lastError: row.lastError,
            updatedAt: ISODate.parse(row.updatedAt) ?? .distantPast
        )
    }
}
