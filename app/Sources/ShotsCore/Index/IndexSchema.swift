/// The index schema, from the original TypeScript daemon (src/db.ts, now in git history) so
/// indexes it created keep working. Everything is `if not exists`, so running it on an existing
/// index changes nothing. Changes since, applied by `Schema.migrate`: `shots.sha256` isn't
/// unique, because a duplicated shot has the same bytes as its original; and the columns in
/// `columns`.
enum Schema {
    /// Added after the TypeScript daemon; `migrate` adds whichever an index is missing.
    ///   scratch: the classifier thinks it's a throwaway (null until judged)
    ///   kept: you said keep it anyway, so it never shows up in Clean Up again
    ///   deleted_at: when it went to Recently Deleted, where it stays for 30 days
    ///   deleted_from: the path it had before (`path` is its place in the hidden folder meanwhile)
    static let columns: [(table: String, name: String, definition: String)] = [
        ("shots", "scratch", "integer"),
        ("shots", "kept", "integer not null default 0"),
        ("shots", "deleted_at", "text"),
        ("shots", "deleted_from", "text"),
    ]

    static let sql = """
    create table if not exists jobs (
      id integer primary key,
      inbox_path text not null,
      original_name text not null,
      detected_at text not null,
      status text not null check (status in ('pending','processing','done','failed','skipped')),
      attempts integer not null default 0,
      last_error text,
      context_json text,
      sha256 text,
      shot_id integer references shots(id),
      updated_at text not null
    );
    create unique index if not exists jobs_active_path on jobs(inbox_path) where status in ('pending','processing');
    create index if not exists jobs_path on jobs(inbox_path);
    create index if not exists jobs_sha on jobs(sha256);

    \(shotsTable("shots"))
    create index if not exists shots_sha on shots(sha256);

    create virtual table if not exists shots_fts using fts5(
      title, ocr_text, tags_text, category, app_name, window_title, url, url_title, original_name,
      content='shots', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2'
    );
    create trigger if not exists shots_ai after insert on shots begin
      insert into shots_fts(rowid, title, ocr_text, tags_text, category, app_name, window_title, url, url_title, original_name)
      values (new.id, new.title, new.ocr_text, new.tags_text, new.category, new.app_name, new.window_title, new.url, new.url_title, new.original_name);
    end;
    create trigger if not exists shots_ad after delete on shots begin
      insert into shots_fts(shots_fts, rowid, title, ocr_text, tags_text, category, app_name, window_title, url, url_title, original_name)
      values ('delete', old.id, old.title, old.ocr_text, old.tags_text, old.category, old.app_name, old.window_title, old.url, old.url_title, old.original_name);
    end;
    create trigger if not exists shots_au after update on shots begin
      insert into shots_fts(shots_fts, rowid, title, ocr_text, tags_text, category, app_name, window_title, url, url_title, original_name)
      values ('delete', old.id, old.title, old.ocr_text, old.tags_text, old.category, old.app_name, old.window_title, old.url, old.url_title, old.original_name);
      insert into shots_fts(rowid, title, ocr_text, tags_text, category, app_name, window_title, url, url_title, original_name)
      values (new.id, new.title, new.ocr_text, new.tags_text, new.category, new.app_name, new.window_title, new.url, new.url_title, new.original_name);
    end;
    """

    /// The `shots` table under `name` (the migration builds it under a temporary one).
    static func shotsTable(_ name: String) -> String {
        """
        create table if not exists \(name) (
          id integer primary key,
          path text not null unique,
          original_name text not null,
          sha256 text not null,
          captured_at text not null,
          processed_at text not null,
          app_bundle_id text,
          app_name text,
          window_title text,
          url text,
          url_title text,
          capture_type text,
          width integer,
          height integer,
          ocr_text text not null default '',
          category text not null,
          suggested_category text,
          tags_json text not null default '[]',
          tags_text text not null default '',
          title text not null,
          confidence real not null,
          backend text not null,
          review integer not null default 0,
          attempts_json text
        );
        """
    }

    /// Brings an index made by an earlier version up to date. Safe to run every time.
    static func migrate(_ db: SQLiteConnection) throws {
        try dropUniqueHash(db)
        for column in columns {
            let existing = try db.query("select name from pragma_table_info(?)", [.text(column.table)]) { $0.string("name") }
            if !existing.contains(column.name) {
                try db.execute("alter table \(column.table) add column \(column.name) \(column.definition)")
            }
        }
        try db.execute("create index if not exists shots_deleted on shots(deleted_at)")
    }

    private static func dropUniqueHash(_ db: SQLiteConnection) throws {
        let ddl = try db.query("select sql from sqlite_master where type = 'table' and name = 'shots'") { $0.string("sql") ?? "" }
        guard let ddl = ddl.first, ddl.contains("sha256 text not null unique") else { return }
        // SQLite can't drop a constraint, so the table is rebuilt (sqlite.org/lang_altertable.html).
        // Foreign keys go off around it: jobs.shot_id points at shots while it's swapped.
        // Columns from `columns` the index already has come along, data and all.
        let existing = try db.query("select name from pragma_table_info('shots')") { $0.string("name") ?? "" }
        let added = columns.filter { $0.table == "shots" && existing.contains($0.name) }
            .map { "alter table shots_new add column \($0.name) \($0.definition);" }
        let names = existing.joined(separator: ", ")
        try db.execute("pragma foreign_keys = off")
        defer { try? db.execute("pragma foreign_keys = on") }
        do {
            try db.execute("""
                begin immediate;
                drop trigger if exists shots_ai;
                drop trigger if exists shots_ad;
                drop trigger if exists shots_au;
                \(shotsTable("shots_new"))
                \(added.joined(separator: "\n"))
                insert into shots_new (\(names)) select \(names) from shots;
                drop table shots;
                alter table shots_new rename to shots;
                \(sql)
                commit;
                """)
        } catch {
            try? db.execute("rollback")
            throw error
        }
    }
}
