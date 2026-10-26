import Foundation
import SQLite3
@testable import ShotsKit

/// A throwaway database with a copy of the daemon's schema, written through its own
/// read-write connection the way the daemon would.
final class TestDatabase {
    let path: String
    private var db: OpaquePointer?

    init() throws {
        path = URL.temporaryDirectory.appending(path: "shots-test-\(UUID().uuidString).db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw SQLiteError(message: "open failed") }
        try exec("pragma journal_mode = wal")
        try exec(Self.schema)
    }

    deinit {
        sqlite3_close(db)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw SQLiteError(message: message.map { String(cString: $0) } ?? "exec failed")
        }
    }

    func insertShot(
        id: Int, category: String, title: String, ocr: String = "", capturedAt: String, review: Bool = false,
        scratch: Bool? = nil, kept: Bool = false, deletedAt: String? = nil
    ) throws {
        try exec("""
            insert into shots (id, path, original_name, sha256, captured_at, processed_at, ocr_text, category,
                               tags_json, tags_text, title, confidence, backend, review, scratch, kept, deleted_at)
            values (\(id), '/tmp/shot-\(id).png', 'Screenshot \(id).png', 'sha\(id)', '\(capturedAt)', '\(capturedAt)',
                    '\(ocr)', '\(category)', '["tag\(id)"]', 'tag\(id)', '\(title)', 0.8, 'apple', \(review ? 1 : 0),
                    \(scratch.map { $0 ? "1" : "0" } ?? "null"), \(kept ? 1 : 0), \(deletedAt.map { "'\($0)'" } ?? "null"))
            """)
    }

    func insertFailedJob(id: Int) throws {
        try exec("""
            insert into jobs (id, inbox_path, original_name, detected_at, status, attempts, last_error, updated_at)
            values (\(id), '/tmp/inbox/job-\(id).png', 'job-\(id).png', '2026-10-21T10:00:00.000Z', 'failed', 3,
                    'every backend failed', '2026-10-21T10:05:00.000Z')
            """)
    }

    static let schema = """
        create table jobs (
          id integer primary key, inbox_path text not null, original_name text not null, detected_at text not null,
          status text not null, attempts integer not null default 0, last_error text, context_json text, sha256 text,
          shot_id integer, updated_at text not null
        );
        create table shots (
          id integer primary key, path text not null unique, original_name text not null, sha256 text not null unique,
          captured_at text not null, processed_at text not null, app_bundle_id text, app_name text, window_title text,
          url text, url_title text, capture_type text, width integer, height integer, ocr_text text not null default '',
          category text not null, suggested_category text, tags_json text not null default '[]',
          tags_text text not null default '', title text not null, confidence real not null, backend text not null,
          review integer not null default 0, attempts_json text, scratch integer, kept integer not null default 0,
          deleted_at text, deleted_from text
        );
        create virtual table shots_fts using fts5(
          title, ocr_text, tags_text, category, app_name, window_title, url, url_title, original_name,
          content='shots', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2'
        );
        create trigger shots_ai after insert on shots begin
          insert into shots_fts(rowid, title, ocr_text, tags_text, category, app_name, window_title, url, url_title, original_name)
          values (new.id, new.title, new.ocr_text, new.tags_text, new.category, new.app_name, new.window_title, new.url, new.url_title, new.original_name);
        end;
        """
}
