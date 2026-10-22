/// The index schema, copied verbatim from src/db.ts so the Swift and TypeScript daemons
/// open the same database. Everything is `if not exists`, so running it on an existing
/// index changes nothing. Change it in both places or not at all.
enum Schema {
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

    create table if not exists shots (
      id integer primary key,
      path text not null unique,
      original_name text not null,
      sha256 text not null unique,
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
}
