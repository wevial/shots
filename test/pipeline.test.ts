import { describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { basename, join } from "node:path";
import { processJob, recat } from "../src/pipeline.ts";
import { appContext, dropFixture, err, fakeNative, MockBackend, ok, tempRoot, testDeps } from "./helpers.ts";

const NAME = "Screenshot 2026-10-21 at 10.22.28 AM.png";

describe("processJob", () => {
  test("files, renames, tags, copies and indexes a screenshot", async () => {
    const root = tempRoot();
    const native = fakeNative({ ocrText: "export function loadConfig(path: string) {}" });
    const backend = new MockBackend("apple", [ok("code", 0.9, "Load config function", ["typescript", "config"])]);
    const deps = testDeps(root, [backend], native);
    const src = dropFixture("code.png", deps.cfg.inbox, NAME);
    const job = deps.store.createJob(src, NAME, appContext());

    const res = await processJob(job.id, deps);
    expect(res.status).toBe("done");
    if (res.status !== "done") return;
    expect(existsSync(src)).toBe(false);
    expect(res.shot.path).toMatch(new RegExp(`${join(deps.cfg.outputRoot, "code")}/\\d{4}-\\d{2}-\\d{2}_\\d{4}_load-config-function\\.png$`));
    expect(existsSync(res.shot.path)).toBe(true);
    expect(native.state.tags.get(res.shot.path)).toEqual(["code", "typescript", "config"]);
    expect(native.state.clipboard).toEqual([res.shot.path]);
    expect(res.shot).toMatchObject({ original_name: NAME, backend: "apple", app_bundle_id: "com.microsoft.VSCode", window_title: "config.ts — shots", review: 0 });
    expect(backend.calls[0]!.appContext?.bundleId).toBe("com.microsoft.VSCode");
    expect(deps.store.getJob(job.id)?.status).toBe("done");

    const hits = deps.store.search("loadconfig");
    expect(hits.map((h) => h.id)).toEqual([res.shot.id]);
    expect(deps.store.search("typescript")).toHaveLength(1);
    expect(deps.store.search("shots")).toHaveLength(1); // window title
  });

  test("same bytes twice: second is skipped and left alone", async () => {
    const root = tempRoot();
    const backend = new MockBackend("apple", [ok("code", 0.9)]);
    const deps = testDeps(root, [backend], fakeNative());
    const a = dropFixture("code.png", deps.cfg.inbox, "a.png");
    await processJob(deps.store.createJob(a, "a.png", null).id, deps);
    const b = dropFixture("code.png", deps.cfg.inbox, "b.png");
    const res = await processJob(deps.store.createJob(b, "b.png", null).id, deps);
    expect(res).toMatchObject({ status: "skipped" });
    expect(existsSync(b)).toBe(true);
    expect(backend.calls).toHaveLength(1);
  });

  test("non-screenshots are skipped and stay in the inbox", async () => {
    const root = tempRoot();
    const backend = new MockBackend("apple", [ok("code", 0.9)]);
    const deps = testDeps(root, [backend], fakeNative({ isScreenCapture: null }));
    const src = dropFixture("blank.png", deps.cfg.inbox, "photo.png");
    const res = await processJob(deps.store.createJob(src, "photo.png", null).id, deps);
    expect(res).toMatchObject({ status: "skipped", reason: expect.stringContaining("not a screen capture") });
    expect(existsSync(src)).toBe(true);
    expect(backend.calls).toHaveLength(0);
  });

  test("requireScreenCapture=false files any image", async () => {
    const root = tempRoot();
    const deps = testDeps(root, [new MockBackend("apple", [ok("design", 0.9)])], fakeNative({ isScreenCapture: null }), { requireScreenCapture: false });
    const src = dropFixture("blank.png", deps.cfg.inbox, "photo.png");
    expect((await processJob(deps.store.createJob(src, "photo.png", null).id, deps)).status).toBe("done");
  });

  test("when every backend fails the file stays put and the job is failed", async () => {
    const root = tempRoot();
    const deps = testDeps(root, [new MockBackend("apple", [err("error", "nope")]), new MockBackend("codex", [err("timeout")], true)], fakeNative());
    const src = dropFixture("code.png", deps.cfg.inbox, NAME);
    const job = deps.store.createJob(src, NAME, null);
    const res = await processJob(job.id, deps);
    expect(res).toMatchObject({ status: "failed", retry: true });
    expect(existsSync(src)).toBe(true);
    expect(deps.store.getJob(job.id)).toMatchObject({ status: "failed", attempts: 1, last_error: expect.stringContaining("all backends failed") });
    expect(existsSync(deps.cfg.outputRoot)).toBe(false);
  });

  test("OCR failure leaves the file in the inbox", async () => {
    const root = tempRoot();
    const deps = testDeps(root, [new MockBackend("apple", [ok("code", 0.9)])], fakeNative({ ocrFails: true }));
    const src = dropFixture("code.png", deps.cfg.inbox, NAME);
    const res = await processJob(deps.store.createJob(src, NAME, null).id, deps);
    expect(res).toMatchObject({ status: "failed", error: "ocr exploded" });
    expect(existsSync(src)).toBe(true);
  });

  test("retry stops after maxAttempts", async () => {
    const root = tempRoot();
    const deps = testDeps(root, [new MockBackend("apple", [err("error")])], fakeNative(), { maxAttempts: 2 });
    const src = dropFixture("code.png", deps.cfg.inbox, NAME);
    const job = deps.store.createJob(src, NAME, null);
    expect(await processJob(job.id, deps)).toMatchObject({ retry: true });
    deps.store.requeueJob(job.id);
    expect(await processJob(job.id, deps)).toMatchObject({ retry: false });
  });

  test("denylisted app: cloud mock is never called", async () => {
    const root = tempRoot();
    const cloud = new MockBackend("claude-code", [ok("finance", 0.99)], true);
    const deps = testDeps(root, [new MockBackend("apple", [err("unavailable", "modelNotReady")]), cloud], fakeNative());
    const src = dropFixture("code.png", deps.cfg.inbox, NAME);
    const ctx = appContext({ bundleId: "com.1password.1password", appName: "1Password" });
    const res = await processJob(deps.store.createJob(src, NAME, ctx).id, deps);
    expect(cloud.calls).toHaveLength(0);
    expect(res.status === "done" && res.shot.backend).toBe("rules");
  });

  test("name collisions get a numeric suffix", async () => {
    const root = tempRoot();
    const deps = testDeps(root, [new MockBackend("apple", [ok("code", 0.9, "Same title")])], fakeNative());
    const paths: string[] = [];
    for (const f of ["code.png", "error.png"]) {
      const src = dropFixture(f, deps.cfg.inbox, f);
      const res = await processJob(deps.store.createJob(src, f, null).id, deps);
      if (res.status === "done") paths.push(basename(res.shot.path));
    }
    // Both were captured within the same minute (fixture copies), so the second gets -2.
    expect(paths[1]).toBe(paths[0]!.replace(".png", "-2.png"));
  });
});

describe("recat", () => {
  test("re-files with a manual category and swaps the tags it applied", async () => {
    const root = tempRoot();
    const native = fakeNative();
    const deps = testDeps(root, [new MockBackend("apple", [ok("code", 0.9, "Thing", ["alpha"])])], native);
    const src = dropFixture("code.png", deps.cfg.inbox, NAME);
    const res = await processJob(deps.store.createJob(src, NAME, null).id, deps);
    if (res.status !== "done") throw new Error("setup failed");
    await native.setTags(res.shot.path, ["user-own-tag"]);

    const { shot } = await recat(res.shot, { category: "design" }, deps);
    expect(shot.path).toContain(`${join(deps.cfg.outputRoot, "design")}/`);
    expect(existsSync(res.shot.path)).toBe(false);
    expect(existsSync(shot.path)).toBe(true);
    expect(shot).toMatchObject({ category: "design", backend: "manual", review: 0 });
    expect(native.state.tags.get(shot.path)?.sort()).toEqual(["alpha", "design"]);
  });

  test("re-classifies with an explicit backend", async () => {
    const root = tempRoot();
    const deps = testDeps(root, [new MockBackend("apple", [ok("misc", 0.3)])], fakeNative());
    const src = dropFixture("code.png", deps.cfg.inbox, NAME);
    const res = await processJob(deps.store.createJob(src, NAME, appContext()).id, deps);
    if (res.status !== "done") throw new Error("setup failed");
    expect(res.shot.review).toBe(1);
    expect(deps.store.reviewQueue()).toHaveLength(1);

    const codex = new MockBackend("codex", [ok("errors", 0.9, "Python traceback")], true);
    const { shot } = await recat(res.shot, { backends: [codex] }, deps);
    expect(codex.calls[0]!.ocrText).toBe(res.shot.ocr_text);
    expect(shot).toMatchObject({ category: "errors", backend: "codex", review: 0, title: "Python traceback" });
    expect(deps.store.reviewQueue()).toHaveLength(0);
    expect(deps.store.search("traceback").map((h) => h.id)).toEqual([shot.id]);
  });

  test("refuses an explicit cloud backend for a denylisted shot", async () => {
    const root = tempRoot();
    const deps = testDeps(root, [new MockBackend("apple", [ok("finance", 0.9)])], fakeNative());
    const src = dropFixture("code.png", deps.cfg.inbox, NAME);
    const ctx = appContext({ bundleId: "com.1password.1password", appName: "1Password" });
    const res = await processJob(deps.store.createJob(src, NAME, ctx).id, deps);
    if (res.status !== "done") throw new Error("setup failed");
    const codex = new MockBackend("codex", [ok("code", 0.9)], true);
    await expect(recat(res.shot, { backends: [codex] }, deps)).rejects.toThrow(/refusing/);
    expect(codex.calls).toHaveLength(0);
  });
});
