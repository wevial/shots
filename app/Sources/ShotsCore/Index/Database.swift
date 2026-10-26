import Foundation

/// Turns free text into an FTS5 query of quoted prefix terms (`"tok"*`), so user input can't
/// inject query syntax. Empty when there are no words in it.
public func toFtsQuery(_ input: String) -> String {
    // Unicode-scalar semantics match JavaScript's /[\p{L}\p{N}_]+/gu (Swift's default is
    // per-grapheme, which would treat a letter plus a combining accent differently).
    let word = /[\p{L}\p{N}_]+/.matchingSemantics(.unicodeScalar)
    return input.matches(of: word).map { "\"\($0.output)\"*" }.joined(separator: " ")
}

/// The read-write side of the index (`<dataDir>/shots.db`): the job queue and the shots.
///
/// The one writer in the process. An actor, so the pipeline's concurrent jobs take turns on
/// the connection; other processes (the viewer, the CLI) can read alongside it because the
/// database is in WAL mode.
public actor Database {
    private let db: SQLiteConnection
    public nonisolated let path: String

    /// Opens or creates the index at `path` (`:memory:` for a throwaway one) and applies the schema.
    public init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(atPath: Paths.dirname(path), withIntermediateDirectories: true)
        }
        let db = try SQLiteConnection(path: path, busyTimeoutMs: 5000)
        _ = try db.query("pragma journal_mode = wal") { _ in () }
        try db.execute("pragma busy_timeout = 5000")
        try db.execute("pragma foreign_keys = on")
        try db.execute(Schema.sql)
        try Schema.migrate(db)
        self.db = db
        self.path = path
    }

    public func close() {
        db.close()
    }

    // MARK: Jobs

    /// Crash recovery: anything mid-flight when the daemon died goes back to pending.
    @discardableResult
    public func resetInterrupted() throws -> Int {
        try db.run("update jobs set status = 'pending', updated_at = ? where status = 'processing'", [.text(Timestamp.now())])
    }

    public func activeJob(forPath path: String) throws -> JobRow? {
        try jobs("select * from jobs where inbox_path = ? and status in ('pending','processing')", [.text(path)]).first
    }

    public func latestJob(forPath path: String) throws -> JobRow? {
        try jobs("select * from jobs where inbox_path = ? order by id desc limit 1", [.text(path)]).first
    }

    public func createJob(path: String, originalName: String, context: AppContext?) throws -> JobRow {
        let now = Timestamp.now()
        return try one(jobs(
            "insert into jobs (inbox_path, original_name, detected_at, status, context_json, updated_at) values (?, ?, ?, 'pending', ?, ?) returning *",
            [.text(path), .text(originalName), .text(now), .nullable(context?.jsonString()), .text(now)]
        ))
    }

    /// Reuses a failed job row for a retry so attempt counts accumulate, keeping its context.
    public func requeueJob(_ id: Int64) throws {
        try db.run("update jobs set status = 'pending', updated_at = ? where id = ?", [.text(Timestamp.now()), .int(id)])
    }

    /// Like `requeueJob(_:)`, but replaces the stored context (nil clears it).
    public func requeueJob(_ id: Int64, context: AppContext?) throws {
        try db.run(
            "update jobs set status = 'pending', context_json = ?, updated_at = ? where id = ?",
            [.nullable(context?.jsonString()), .text(Timestamp.now()), .int(id)]
        )
    }

    public func job(id: Int64) throws -> JobRow? {
        try jobs("select * from jobs where id = ?", [.int(id)]).first
    }

    public func pendingJobs() throws -> [JobRow] {
        try jobs("select * from jobs where status = 'pending' order by id")
    }

    /// Marks the job processing and counts the attempt.
    public func startJob(_ id: Int64) throws -> JobRow {
        try one(jobs(
            "update jobs set status = 'processing', attempts = attempts + 1, updated_at = ? where id = ? returning *",
            [.text(Timestamp.now()), .int(id)]
        ))
    }

    /// Ends a job. `error` replaces `last_error` (nil clears it); `sha256` and `shotId` only
    /// fill in when given.
    public func finishJob(_ id: Int64, status: JobStatus, error: String? = nil, sha256: String? = nil, shotId: Int64? = nil) throws {
        precondition(status == .done || status == .failed || status == .skipped, "finishJob needs a final status")
        try db.run(
            "update jobs set status = ?, last_error = ?, sha256 = coalesce(?, sha256), shot_id = coalesce(?, shot_id), updated_at = ? where id = ?",
            [.text(status.rawValue), .nullable(error), .nullable(sha256), .nullable(shotId), .text(Timestamp.now()), .int(id)]
        )
    }

    /// A non-duplicate job that was skipped for this content (e.g. "not a screenshot"), so
    /// the same bytes under a new name aren't looked at again.
    public func skippedJob(forSha sha: String, except id: Int64) throws -> JobRow? {
        try jobs("select * from jobs where sha256 = ? and status = 'skipped' and id != ? limit 1", [.text(sha), .int(id)]).first
    }

    public func failedJobs() throws -> [JobRow] {
        try jobs("select * from jobs where status = 'failed' order by updated_at desc")
    }

    // MARK: Shots

    /// A shot in the library with these bytes. Recently Deleted doesn't count: capturing the
    /// same thing again files it.
    public func shot(bySha sha: String) throws -> ShotRow? {
        try shots("select * from shots where sha256 = ? and deleted_at is null", [.text(sha)]).first
    }

    public func shot(id: Int64) throws -> ShotRow? {
        try shots("select * from shots where id = ?", [.int(id)]).first
    }

    public func insertShot(_ s: NewShot) throws -> ShotRow {
        try one(shots(
            """
            insert into shots (path, original_name, sha256, captured_at, processed_at, app_bundle_id, app_name,
              window_title, url, url_title, capture_type, width, height, ocr_text, category, suggested_category,
              tags_json, tags_text, title, confidence, backend, review, attempts_json, scratch)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) returning *
            """,
            [
                .text(s.path), .text(s.originalName), .text(s.sha256), .text(s.capturedAt), .text(s.processedAt),
                .nullable(s.appBundleId), .nullable(s.appName), .nullable(s.windowTitle), .nullable(s.url),
                .nullable(s.urlTitle), .nullable(s.captureType), .nullable(s.width), .nullable(s.height),
                .text(s.ocrText), .text(s.category), .nullable(s.suggestedCategory), .text(tagsJSON(s.tags)),
                .text(s.tags.joined(separator: " ")), .text(s.title), .double(s.confidence), .text(s.backend),
                .int(s.review ? 1 : 0), .nullable(s.attemptsJSON), .nullable(s.scratch.map { $0 ? 1 : 0 }),
            ]
        ))
    }

    public func updateShot(_ id: Int64, _ u: ShotUpdate) throws -> ShotRow {
        try one(shots(
            """
            update shots set path = ?, category = ?, suggested_category = ?, tags_json = ?, tags_text = ?, title = ?,
              confidence = ?, backend = ?, review = ?, attempts_json = ?, processed_at = ?, scratch = ?
            where id = ? returning *
            """,
            [
                .text(u.path), .text(u.category), .nullable(u.suggestedCategory), .text(tagsJSON(u.tags)),
                .text(u.tags.joined(separator: " ")), .text(u.title), .double(u.confidence), .text(u.backend),
                .int(u.review ? 1 : 0), .nullable(u.attemptsJSON), .text(u.processedAt),
                .nullable(u.scratch.map { $0 ? 1 : 0 }), .int(id),
            ]
        ))
    }

    /// New pixels in the same file (cropped or rotated, here or in another app): what was read
    /// from the image changes, how it was filed doesn't.
    public func updateShotContent(_ id: Int64, sha256: String, width: Int, height: Int, ocrText: String) throws -> ShotRow {
        try one(shots(
            "update shots set sha256 = ?, width = ?, height = ?, ocr_text = ? where id = ? returning *",
            [.text(sha256), .int(Int64(width)), .int(Int64(height)), .text(ocrText), .int(id)]
        ))
    }

    /// The shot filed at exactly `path`, if any.
    public func shot(atPath path: String) throws -> ShotRow? {
        try shots("select * from shots where path = ?", [.text(path)]).first
    }

    /// Puts a shot in Recently Deleted: its file is now at `path`, and was at `from`.
    public func markDeleted(_ id: Int64, path: String, from: String, at date: String = Timestamp.now()) throws -> ShotRow {
        try one(shots(
            "update shots set path = ?, deleted_from = ?, deleted_at = ? where id = ? returning *",
            [.text(path), .text(from), .text(date), .int(id)]
        ))
    }

    /// Brings a shot back from Recently Deleted, its file now at `path`.
    public func markRestored(_ id: Int64, path: String) throws -> ShotRow {
        try one(shots(
            "update shots set path = ?, deleted_from = null, deleted_at = null where id = ? returning *",
            [.text(path), .int(id)]
        ))
    }

    /// Shots that went to Recently Deleted before `date`, oldest first.
    public func deletedShots(before date: String) throws -> [ShotRow] {
        try shots("select * from shots where deleted_at < ? order by deleted_at", [.text(date)])
    }

    /// Takes a shot out of the index for good. The job that filed it stays, unlinked.
    public func removeShot(_ id: Int64) throws {
        try db.execute("begin immediate")
        do {
            try db.run("update jobs set shot_id = null where shot_id = ?", [.int(id)])
            try db.run("delete from shots where id = ?", [.int(id)])
            try db.execute("commit")
        } catch {
            try? db.execute("rollback")
            throw error
        }
    }

    /// Undoes an insert whose file move failed.
    public func deleteShot(_ id: Int64) throws {
        try db.run("delete from shots where id = ?", [.int(id)])
    }

    // MARK: Clean Up

    public func setScratch(_ id: Int64, _ scratch: Bool) throws {
        try db.run("update shots set scratch = ? where id = ?", [.int(scratch ? 1 : 0), .int(id)])
    }

    /// Keeps a shot out of Clean Up for good, whatever the classifier says later.
    public func keep(_ id: Int64) throws {
        try db.run("update shots set kept = 1 where id = ?", [.int(id)])
    }

    /// Scratch shots captured before `cutoff` that nobody chose to keep, newest first.
    public func cleanupSuggestions(capturedBefore cutoff: Date) throws -> [ShotRow] {
        try shots(
            "select * from shots where scratch = 1 and kept = 0 and captured_at < ? and deleted_at is null order by captured_at desc",
            [.text(Timestamp.string(from: cutoff))]
        )
    }

    /// Shots filed before the classifier judged scratch, newest first.
    public func unjudgedShots() throws -> [ShotRow] {
        try shots("select * from shots where scratch is null and kept = 0 and deleted_at is null order by captured_at desc")
    }

    /// Lookup for `recat`: the exact path first, then the original or current file name.
    public func findShot(_ ref: String, resolvedPath: String) throws -> ShotRow? {
        if let exact = try shots("select * from shots where path = ? and deleted_at is null", [.text(resolvedPath)]).first { return exact }
        return try shots(
            "select * from shots where (original_name = ?1 or path like '%/' || ?2) and deleted_at is null order by id desc limit 1",
            [.text(ref), .text(ref)]
        ).first
    }

    /// Full-text search over title, OCR, tags, category, app, window, URL and file name,
    /// best match first.
    public func search(_ query: String, limit: Int = 20) throws -> [SearchHit] {
        let fts = toFtsQuery(query)
        guard !fts.isEmpty else { return [] }
        return try db.query(
            """
            select s.*, snippet(shots_fts, 1, '[', ']', '…', 12) as snippet
            from shots_fts join shots s on s.id = shots_fts.rowid
            where shots_fts match ? and s.deleted_at is null order by bm25(shots_fts, 5.0, 1.0, 3.0, 2.0, 1.0, 2.0, 1.0, 2.0, 1.0) limit ?
            """,
            [.text(fts), .int(Int64(limit))]
        ) { SearchHit(shot: ShotRow(row: $0), snippet: $0.string("snippet") ?? "") }
    }

    public func reviewQueue() throws -> [ShotRow] {
        try shots("select * from shots where review = 1 and deleted_at is null order by captured_at desc")
    }

    public func stats() throws -> IndexStats {
        let jobs = try db.query("select status, count(*) n from jobs group by status") {
            ($0.string("status") ?? "", Int($0.int("n") ?? 0))
        }
        let totals = try one(db.query("select count(*) n, coalesce(sum(review),0) review from shots where deleted_at is null") {
            (shots: Int($0.int("n") ?? 0), review: Int($0.int("review") ?? 0))
        })
        let byBackend = try db.query("select backend, count(*) n from shots where deleted_at is null group by backend") {
            IndexStats.BackendCount(backend: $0.string("backend") ?? "", count: Int($0.int("n") ?? 0))
        }
        return IndexStats(
            jobs: Dictionary(jobs, uniquingKeysWith: +), shots: totals.shots, review: totals.review, byBackend: byBackend
        )
    }

    // MARK: Helpers

    private func jobs(_ sql: String, _ bindings: [SQLiteConnection.Binding] = []) throws -> [JobRow] {
        try db.query(sql, bindings, row: JobRow.init(row:))
    }

    private func shots(_ sql: String, _ bindings: [SQLiteConnection.Binding] = []) throws -> [ShotRow] {
        try db.query(sql, bindings, row: ShotRow.init(row:))
    }

    /// For `returning *` statements, which always give back a row unless the id was wrong.
    private func one<T>(_ rows: [T]) throws -> T {
        guard let first = rows.first else { throw SQLiteError(message: "no such row") }
        return first
    }
}
