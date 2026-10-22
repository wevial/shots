import Foundation

/// Read-only access to the daemon's SQLite index.
///
/// The daemon writes to the same database at any time (WAL mode lets readers and one writer
/// work side by side). This app never writes to it: every change goes through the `shots` CLI.
/// An actor, so queries run off the main thread and the connection is used by one task at a time.
public actor ShotStore {
    private let db: SQLiteConnection
    public nonisolated let path: String

    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SQLiteError(message: "No screenshot index at \(path). Is the shots daemon installed?")
        }
        self.path = path
        db = try SQLiteConnection(readOnlyPath: path)
    }

    /// Shots in `scope`, newest first, or ranked by relevance when `search` has words in it.
    public func shots(in scope: SidebarScope, matching search: String = "", limit: Int = 5000) throws -> [Shot] {
        var conditions: [String] = []
        var bindings: [SQLiteConnection.Binding] = []

        switch scope {
        case .all: break
        case .review: conditions.append("s.review = 1")
        case .category(let name):
            conditions.append("s.category = ?")
            bindings.append(.text(name))
        case .failed: return [] // Failed items are jobs, not shots; see `failedJobs()`.
        }

        var sql = "select s.* from shots s"
        let order: String
        if let fts = FTSQuery.build(search) {
            sql += " join shots_fts on shots_fts.rowid = s.id"
            conditions.insert("shots_fts match ?", at: 0)
            bindings.insert(.text(fts), at: 0)
            // Column weights: title, ocr_text, tags_text, category, app_name, window_title, url, url_title, original_name.
            order = "bm25(shots_fts, 5.0, 1.0, 3.0, 2.0, 1.0, 2.0, 1.0, 2.0, 1.0)"
        } else {
            order = "s.captured_at desc, s.id desc"
        }
        if !conditions.isEmpty { sql += " where " + conditions.joined(separator: " and ") }
        sql += " order by \(order) limit ?"
        bindings.append(.int(Int64(limit)))

        return try db.query(sql, bindings, row: Self.shot)
    }

    public func recentShots(limit: Int = 5) throws -> [Shot] {
        try db.query("select * from shots order by captured_at desc, id desc limit ?", [.int(Int64(limit))], row: Self.shot)
    }

    public func shot(id: Shot.ID) throws -> Shot? {
        try db.query("select * from shots where id = ?", [.int(id)], row: Self.shot).first
    }

    public func failedJobs() throws -> [FailedJob] {
        try db.query("select * from jobs where status = 'failed' order by updated_at desc", row: Self.failedJob)
    }

    public func counts() throws -> ScopeCounts {
        let totals = try db.query("select count(*) as n, coalesce(sum(review), 0) as review from shots") {
            (all: Int($0.int("n") ?? 0), review: Int($0.int("review") ?? 0))
        }.first ?? (all: 0, review: 0)
        let failed = try db.query("select count(*) as n from jobs where status = 'failed'") { Int($0.int("n") ?? 0) }.first ?? 0
        let byCategory = try db.query("select category, count(*) as n from shots group by category") {
            ($0.string("category") ?? "", Int($0.int("n") ?? 0))
        }
        return ScopeCounts(
            all: totals.all,
            review: totals.review,
            failed: failed,
            byCategory: Dictionary(byCategory, uniquingKeysWith: +)
        )
    }

    /// Changes whenever another connection (the daemon or the CLI) commits to the database.
    /// Cheap enough to poll every couple of seconds.
    public func dataVersion() throws -> Int64 {
        try db.query("pragma data_version") { $0.int("data_version") ?? 0 }.first ?? 0
    }

    // MARK: Row mapping

    private static func shot(_ row: SQLiteConnection.Row) throws -> Shot {
        Shot(
            id: row.int("id") ?? 0,
            path: row.string("path") ?? "",
            originalName: row.string("original_name") ?? "",
            sha256: row.string("sha256") ?? "",
            capturedAt: row.string("captured_at").flatMap(ISODate.parse) ?? .distantPast,
            processedAt: row.string("processed_at").flatMap(ISODate.parse) ?? .distantPast,
            appBundleID: row.string("app_bundle_id"),
            appName: row.string("app_name"),
            windowTitle: row.string("window_title"),
            pageURL: row.string("url").flatMap(URL.init(string:)),
            pageTitle: row.string("url_title"),
            captureType: row.string("capture_type"),
            width: row.int("width").map(Int.init),
            height: row.int("height").map(Int.init),
            ocrText: row.string("ocr_text") ?? "",
            category: row.string("category") ?? "misc",
            suggestedCategory: row.string("suggested_category"),
            tags: Shot.decodeTags(row.string("tags_json")),
            title: row.string("title") ?? "",
            confidence: row.double("confidence") ?? 0,
            backend: row.string("backend") ?? "",
            needsReview: (row.int("review") ?? 0) != 0
        )
    }

    private static func failedJob(_ row: SQLiteConnection.Row) throws -> FailedJob {
        FailedJob(
            id: row.int("id") ?? 0,
            inboxPath: row.string("inbox_path") ?? "",
            originalName: row.string("original_name") ?? "",
            detectedAt: row.string("detected_at").flatMap(ISODate.parse) ?? .distantPast,
            attempts: Int(row.int("attempts") ?? 0),
            lastError: row.string("last_error"),
            updatedAt: row.string("updated_at").flatMap(ISODate.parse) ?? .distantPast
        )
    }
}
