// Regenerates fixture.db with the daemon's real schema.
// Run from the repo root: bun app/Tests/ShotsKitTests/Fixtures/make-fixture-db.ts
import { rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { Store, type NewShot } from "../../../../src/db.ts";

const out = join(dirname(import.meta.path), "fixture.db");
for (const s of ["", "-wal", "-shm"]) rmSync(out + s, { force: true });

const store = new Store(out);

function shot(n: number, o: Partial<NewShot> & Pick<NewShot, "category" | "title" | "captured_at">): void {
  store.insertShot({
    path: `/fixture/Screenshots/${o.category}/shot-${n}.png`,
    original_name: `Screenshot ${n}.png`,
    sha256: `sha-${n}`,
    processed_at: o.captured_at,
    app_bundle_id: null,
    app_name: null,
    window_title: null,
    url: null,
    url_title: null,
    capture_type: "selection",
    width: 1440,
    height: 900,
    ocr_text: "",
    suggested_category: null,
    tags_json: "[]",
    confidence: 0.9,
    backend: "apple",
    review: 0,
    attempts_json: null,
    ...o,
  });
}

shot(1, { category: "errors", title: "Swift compiler failure", captured_at: "2026-10-18T09:00:00.000Z",
  ocr_text: "error: cannot find type Widget in scope", tags_json: '["swift","compiler"]', app_name: "Xcode" });
shot(2, { category: "ui-reference", title: "Dashboard layout", captured_at: "2026-10-19T09:00:00.000Z",
  ocr_text: "Queued workers throughput", tags_json: '["dashboard","charts"]', backend: "claude-code",
  url: "https://example.com/dashboard", url_title: "Example Dashboard", app_name: "Google Chrome", window_title: "Dashboard" });
shot(3, { category: "receipts", title: "Coffee receipt", captured_at: "2026-10-20T09:00:00.000Z",
  ocr_text: "Total 4.50 espresso", tags_json: '["receipt"]' });
shot(4, { category: "misc", title: "Unclear screenshot", captured_at: "2026-10-21T09:00:00.000Z",
  ocr_text: "invoice number 1042", tags_json: '["invoice"]', review: 1, suggested_category: "receipts", confidence: 0.4 });
shot(5, { category: "design", title: "Logo sketch", captured_at: "2026-10-17T09:00:00.000Z",
  ocr_text: "", tags_json: '["logo"]', backend: "manual" });
shot(6, { category: "errors", title: "Network timeout", captured_at: "2026-10-16T09:00:00.000Z",
  ocr_text: "ETIMEDOUT connecting to database", tags_json: '["network","timeout"]' });

const done = store.createJob("/fixture/inbox/done.png", "done.png", null);
store.finishJob(done.id, "done", { shotId: 1 });
const failed = store.createJob("/fixture/inbox/broken.png", "broken.png", null);
store.startJob(failed.id);
store.finishJob(failed.id, "failed", { error: "every backend failed" });

store.db.run("pragma wal_checkpoint(truncate)");
store.db.run("pragma journal_mode = delete");
store.close();
console.log("wrote", out);
