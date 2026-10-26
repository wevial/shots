import Foundation
import ShotsCore

/// The store's errors are ShotsCore's SQLite errors.
public typealias SQLiteError = ShotsCore.SQLiteError

/// Read-only access to the daemon's SQLite index.
///
/// The daemon writes to the same database at any time (WAL mode lets readers and one writer
/// work side by side). This app never writes to it: every change goes through the `shots` CLI.
/// An actor, so queries run off the main thread and the connection is used by one task at a time.
public actor ShotStore {
    private let db: SQLiteConnection
    public nonisolated let path: String
    /// Whether the index has the scratch columns yet (the app's own `Database` adds them).
    private var hasScratchColumns = false
    /// Whether the index has Recently Deleted's columns yet: the daemon adds them when it
    /// opens an older index, which may be after this store did.
    private var knowsDeletes = false

    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SQLiteError(message: "No screenshot index at \(path). Is the shots daemon installed?")
        }
        self.path = path
        db = try SQLiteConnection(readOnlyPath: path)
    }

    /// Shots in `scope`, newest first, or ranked by relevance when `search` has words in it.
    /// Clean Up holds scratch shots captured before `cleanupCutoff`.
    public func shots(
        in scope: SidebarScope, matching search: String = "", limit: Int = 5000, cleanupCutoff: Date = .now
    ) throws -> [Shot] {
        guard try tracksDeletes() || scope != .deleted else { return [] }
        var conditions = [scope == .deleted ? "s.deleted_at is not null" : try inLibrary("s.")]
        var bindings: [SQLiteConnection.Binding] = []

        switch scope {
        case .all, .deleted: break
        case .review: conditions.append("s.review = 1")
        case .category(let name):
            conditions.append("s.category = ?")
            bindings.append(.text(name))
        case .failed: return [] // Failed items are jobs, not shots; see `failedJobs()`.
        case .cleanup:
            guard try scratchColumnsExist() else { return [] }
            conditions.append(Self.cleanupCondition)
            bindings.append(.text(Timestamp.string(from: cleanupCutoff)))
        }

        var sql = "select s.* from shots s"
        let order: String
        if let fts = FTSQuery.build(search) {
            sql += " join shots_fts on shots_fts.rowid = s.id"
            conditions.insert("shots_fts match ?", at: 0)
            bindings.insert(.text(fts), at: 0)
            // Column weights: title, ocr_text, tags_text, category, app_name, window_title, url, url_title, original_name.
            order = "bm25(shots_fts, 5.0, 1.0, 3.0, 2.0, 1.0, 2.0, 1.0, 2.0, 1.0)"
        } else if scope == .deleted {
            order = "s.deleted_at desc, s.id desc"
        } else {
            order = "s.captured_at desc, s.id desc"
        }
        sql += " where " + conditions.joined(separator: " and ")
        sql += " order by \(order) limit ?"
        bindings.append(.int(Int64(limit)))

        return try db.query(sql, bindings, row: Self.shot)
    }

    public func recentShots(limit: Int = 5) throws -> [Shot] {
        try db.query("select * from shots where \(try inLibrary()) order by captured_at desc, id desc limit ?", [.int(Int64(limit))], row: Self.shot)
    }

    public func shot(id: Shot.ID) throws -> Shot? {
        try db.query("select * from shots where id = ?", [.int(id)], row: Self.shot).first
    }

    public func failedJobs() throws -> [FailedJob] {
        try db.query("select * from jobs where status = 'failed' order by updated_at desc", row: Self.failedJob)
    }

    public func counts(cleanupCutoff: Date = .now) throws -> ScopeCounts {
        let inLibrary = try inLibrary()
        let totals = try db.query(
            """
            select count(*) filter (where \(inLibrary)) as n,
              count(*) filter (where \(inLibrary) and review = 1) as review,
              count(*) filter (where not (\(inLibrary))) as deleted
            from shots
            """
        ) {
            (all: Int($0.int("n") ?? 0), review: Int($0.int("review") ?? 0), deleted: Int($0.int("deleted") ?? 0))
        }.first ?? (all: 0, review: 0, deleted: 0)
        let failed = try db.query("select count(*) as n from jobs where status = 'failed'") { Int($0.int("n") ?? 0) }.first ?? 0
        let byCategory = try db.query("select category, count(*) as n from shots where \(inLibrary) group by category") {
            ($0.string("category") ?? "", Int($0.int("n") ?? 0))
        }
        var cleanup = 0, unjudged = 0
        if try scratchColumnsExist() {
            cleanup = try db.query("select count(*) as n from shots s where \(Self.cleanupCondition) and \(try self.inLibrary("s."))", [.text(Timestamp.string(from: cleanupCutoff))]) {
                Int($0.int("n") ?? 0)
            }.first ?? 0
            unjudged = try db.query("select count(*) as n from shots where scratch is null and kept = 0 and \(inLibrary)") { Int($0.int("n") ?? 0) }.first ?? 0
        }
        return ScopeCounts(
            all: totals.all,
            review: totals.review,
            failed: failed,
            cleanup: cleanup,
            unjudged: unjudged,
            deleted: totals.deleted,
            byCategory: Dictionary(byCategory, uniquingKeysWith: +)
        )
    }

    /// Binds one value: the cutoff.
    private static let cleanupCondition = "s.scratch = 1 and s.kept = 0 and s.captured_at < ?"

    /// Rechecked until they appear: a store can open an index the app hasn't migrated yet.
    private func scratchColumnsExist() throws -> Bool {
        if !hasScratchColumns {
            hasScratchColumns = try db.query("select count(*) as n from pragma_table_info('shots') where name = 'scratch'") {
                ($0.int("n") ?? 0) > 0
            }.first ?? false
        }
        return hasScratchColumns
    }

    /// Changes whenever another connection (the daemon or the CLI) commits to the database.
    /// Cheap enough to poll every couple of seconds.
    public func dataVersion() throws -> Int64 {
        try db.query("pragma data_version") { $0.int("data_version") ?? 0 }.first ?? 0
    }

    /// The condition for a shot in the library rather than Recently Deleted (always true in an
    /// index that doesn't track deletes yet). `table` prefixes the column, e.g. `s.`.
    private func inLibrary(_ table: String = "") throws -> String {
        try tracksDeletes() ? "\(table)deleted_at is null" : "1"
    }

    private func tracksDeletes() throws -> Bool {
        if !knowsDeletes {
            knowsDeletes = try db.query("pragma table_info(shots)") { $0.string("name") }.contains("deleted_at")
        }
        return knowsDeletes
    }

    // MARK: Row mapping

    private static func shot(_ row: SQLiteConnection.Row) throws -> Shot {
        Shot(row: ShotRow(row: row))
    }

    private static func failedJob(_ row: SQLiteConnection.Row) throws -> FailedJob {
        FailedJob(row: JobRow(row: row))
    }
}
