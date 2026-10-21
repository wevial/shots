import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { AppContext } from "./native.ts";

export type JobStatus = "pending" | "processing" | "done" | "failed" | "skipped";

export interface JobRow {
  id: number;
  inbox_path: string;
  original_name: string;
  detected_at: string;
  status: JobStatus;
  attempts: number;
  last_error: string | null;
  context_json: string | null;
  sha256: string | null;
  shot_id: number | null;
  updated_at: string;
}

export interface ShotRow {
  id: number;
  path: string;
  original_name: string;
  sha256: string;
  captured_at: string;
  processed_at: string;
  app_bundle_id: string | null;
  app_name: string | null;
  window_title: string | null;
  url: string | null;
  url_title: string | null;
  capture_type: string | null;
  width: number | null;
  height: number | null;
  ocr_text: string;
  category: string;
  suggested_category: string | null;
  tags_json: string;
  tags_text: string;
  title: string;
  confidence: number;
  backend: string;
  review: number;
  attempts_json: string | null;
}

export type NewShot = Omit<ShotRow, "id" | "tags_text">;

const SCHEMA = `
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
`;

const now = () => new Date().toISOString();

/** Turns free text into an FTS5 query of quoted terms (prefix-matched), so user input can't inject syntax. */
export function toFtsQuery(input: string): string {
  const terms = input.match(/[\p{L}\p{N}_]+/gu) ?? [];
  return terms.map((t) => `"${t}"*`).join(" ");
}

export class Store {
  readonly db: Database;

  constructor(path: string) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new Database(path, { create: true, strict: true });
    this.db.run("pragma journal_mode = wal");
    this.db.run("pragma busy_timeout = 5000");
    this.db.run("pragma foreign_keys = on");
    this.db.exec(SCHEMA);
  }

  close() {
    this.db.close();
  }

  /** Crash recovery: anything mid-flight when the daemon died goes back to pending. */
  resetInterrupted(): number {
    return this.db.run("update jobs set status = 'pending', updated_at = ? where status = 'processing'", [now()]).changes;
  }

  activeJobForPath(path: string): JobRow | null {
    return this.db.query<JobRow, [string]>("select * from jobs where inbox_path = ? and status in ('pending','processing')").get(path);
  }

  latestJobForPath(path: string): JobRow | null {
    return this.db.query<JobRow, [string]>("select * from jobs where inbox_path = ? order by id desc limit 1").get(path);
  }

  createJob(path: string, originalName: string, context: AppContext | null): JobRow {
    return this.db
      .query<JobRow, [string, string, string, string | null, string]>(
        "insert into jobs (inbox_path, original_name, detected_at, status, context_json, updated_at) values (?, ?, ?, 'pending', ?, ?) returning *",
      )
      .get(path, originalName, now(), context ? JSON.stringify(context) : null, now())!;
  }

  /** Reuse a failed job row for a retry so attempt counts accumulate. */
  requeueJob(id: number, context?: AppContext | null): void {
    if (context === undefined) this.db.run("update jobs set status = 'pending', updated_at = ? where id = ?", [now(), id]);
    else this.db.run("update jobs set status = 'pending', context_json = ?, updated_at = ? where id = ?", [context ? JSON.stringify(context) : null, now(), id]);
  }

  getJob(id: number): JobRow | null {
    return this.db.query<JobRow, [number]>("select * from jobs where id = ?").get(id);
  }

  pendingJobs(): JobRow[] {
    return this.db.query<JobRow, []>("select * from jobs where status = 'pending' order by id").all();
  }

  startJob(id: number): JobRow {
    return this.db
      .query<JobRow, [string, number]>("update jobs set status = 'processing', attempts = attempts + 1, updated_at = ? where id = ? returning *")
      .get(now(), id)!;
  }

  finishJob(id: number, status: Exclude<JobStatus, "pending" | "processing">, fields: { error?: string; sha256?: string; shotId?: number } = {}) {
    this.db.run(
      "update jobs set status = ?, last_error = ?, sha256 = coalesce(?, sha256), shot_id = coalesce(?, shot_id), updated_at = ? where id = ?",
      [status, fields.error ?? null, fields.sha256 ?? null, fields.shotId ?? null, now(), id],
    );
  }

  /** A non-duplicate job that was skipped for this content (e.g. "not a screenshot") — don't redo it. */
  skippedJobForSha(sha: string, exceptId: number): JobRow | null {
    return this.db.query<JobRow, [string, number]>("select * from jobs where sha256 = ? and status = 'skipped' and id != ? limit 1").get(sha, exceptId);
  }

  shotBySha(sha: string): ShotRow | null {
    return this.db.query<ShotRow, [string]>("select * from shots where sha256 = ?").get(sha);
  }

  insertShot(s: NewShot): ShotRow {
    const tags = JSON.parse(s.tags_json) as string[];
    const row = { ...s, tags_text: tags.join(" ") };
    const cols = Object.keys(row);
    return this.db
      .query<ShotRow, any[]>(`insert into shots (${cols.join(",")}) values (${cols.map(() => "?").join(",")}) returning *`)
      .get(...Object.values(row))!;
  }

  updateShot(id: number, patch: Partial<Omit<ShotRow, "id" | "tags_text">>): ShotRow {
    const row: Record<string, unknown> = { ...patch };
    if (patch.tags_json) row.tags_text = (JSON.parse(patch.tags_json) as string[]).join(" ");
    const cols = Object.keys(row);
    return this.db
      .query<ShotRow, any[]>(`update shots set ${cols.map((c) => `${c} = ?`).join(", ")} where id = ? returning *`)
      .get(...(Object.values(row) as any[]), id)!;
  }

  /** Lookup for `recat`: exact path, then original or current file name. */
  findShot(ref: string, resolvedPath: string): ShotRow | null {
    return (
      this.db.query<ShotRow, [string]>("select * from shots where path = ?").get(resolvedPath) ??
      this.db
        .query<ShotRow, [string, string]>("select * from shots where original_name = ?1 or path like '%/' || ?2 order by id desc limit 1")
        .get(ref, ref)
    );
  }

  search(query: string, limit = 20) {
    const fts = toFtsQuery(query);
    if (!fts) return [];
    return this.db
      .query<ShotRow & { snippet: string }, [string, number]>(
        `select s.*, snippet(shots_fts, 1, '[', ']', '…', 12) as snippet
         from shots_fts join shots s on s.id = shots_fts.rowid
         where shots_fts match ? order by bm25(shots_fts, 5.0, 1.0, 3.0, 2.0, 1.0, 2.0, 1.0, 2.0, 1.0) limit ?`,
      )
      .all(fts, limit);
  }

  reviewQueue(): ShotRow[] {
    return this.db.query<ShotRow, []>("select * from shots where review = 1 order by captured_at desc").all();
  }

  failedJobs(): JobRow[] {
    return this.db.query<JobRow, []>("select * from jobs where status = 'failed' order by updated_at desc").all();
  }

  stats() {
    const jobs = this.db.query<{ status: string; n: number }, []>("select status, count(*) n from jobs group by status").all();
    const shots = this.db.query<{ n: number; review: number }, []>("select count(*) n, coalesce(sum(review),0) review from shots").get()!;
    const byBackend = this.db.query<{ backend: string; n: number }, []>("select backend, count(*) n from shots group by backend").all();
    return { jobs: Object.fromEntries(jobs.map((j) => [j.status, j.n])), shots: shots.n, review: shots.review, byBackend };
  }
}
