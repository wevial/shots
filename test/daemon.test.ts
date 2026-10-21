import { describe, expect, test } from "bun:test";
import { existsSync, readdirSync, renameSync } from "node:fs";
import { join } from "node:path";
import { Daemon } from "../src/daemon.ts";
import { Store } from "../src/db.ts";
import { appContext, dropFixture, err, fakeNative, MockBackend, ok, tempRoot, testDeps, until } from "./helpers.ts";

const filed = (dir: string) => (existsSync(dir) ? readdirSync(dir, { recursive: true }).filter((f) => String(f).endsWith(".png")) : []);

describe("Daemon", () => {
  test("picks up new files, captures context at detection, ignores hidden temp files", async () => {
    const root = tempRoot();
    const native = fakeNative();
    const backend = new MockBackend("apple", [ok("code", 0.9)]);
    const deps = testDeps(root, [backend], native);
    const daemon = new Daemon(deps, { rescanMs: 60_000 });
    daemon.start();
    // macOS writes a hidden temp file then renames it into place.
    const tmp = dropFixture("code.png", deps.cfg.inbox, ".Screenshot temp.png");
    await new Promise((r) => setTimeout(r, 100));
    expect(native.state.contextCalls).toBe(0);
    renameSync(tmp, join(deps.cfg.inbox, "Screenshot 1.png"));
    await until(() => filed(join(deps.cfg.outputRoot, "code")).length === 1);
    await daemon.stop();
    expect(native.state.contextCalls).toBe(1);
    expect(backend.calls[0]!.appContext?.bundleId).toBe("com.microsoft.VSCode");
    expect(readdirSync(deps.cfg.inbox)).toEqual([]);
  });

  test("bursts queue with bounded concurrency", async () => {
    const root = tempRoot();
    const backend = new MockBackend("claude-code", [ok("code", 0.9)], true, 40);
    const deps = testDeps(root, [backend], fakeNative(), { concurrency: 2 });
    const daemon = new Daemon(deps);
    daemon.start();
    for (const [i, f] of ["code.png", "error.png", "receipt.png", "blank.png"].entries()) dropFixture(f, deps.cfg.inbox, `Screenshot ${i}.png`);
    await until(() => filed(join(deps.cfg.outputRoot, "code")).length === 4, 8000);
    await daemon.stop();
    expect(backend.calls).toHaveLength(4);
    expect(backend.maxActive).toBeLessThanOrEqual(2);
  });

  test("survives a restart: interrupted jobs resume, finished ones don't rerun", async () => {
    const root = tempRoot();
    const first = testDeps(root, [new MockBackend("apple", [ok("code", 0.9)])], fakeNative());
    // Simulate a crash mid-job: a file whose job is stuck in "processing".
    const stuck = dropFixture("error.png", first.cfg.inbox, "Screenshot stuck.png");
    const job = first.store.createJob(stuck, "Screenshot stuck.png", null);
    first.store.startJob(job.id);
    first.store.close();

    const backend = new MockBackend("apple", [ok("errors", 0.9)]);
    const second = testDeps(root, [backend], fakeNative());
    const d2 = new Daemon(second);
    d2.start();
    await until(() => filed(join(second.cfg.outputRoot, "errors")).length === 1);
    await d2.stop();
    expect(second.store.getJob(job.id)).toMatchObject({ status: "done", attempts: 2 });
    second.store.close();

    const third = testDeps(root, [new MockBackend("apple", [ok("code", 0.9)])], fakeNative());
    const d3 = new Daemon(third);
    d3.start();
    await d3.scan();
    await d3.stop();
    expect((third.backends[0] as MockBackend).calls).toHaveLength(0);
    expect(new Store(join(third.cfg.dataDir, "shots.db")).stats().shots).toBe(1);
  });

  test("files already in the inbox at startup are processed without stale context", async () => {
    const root = tempRoot();
    const native = fakeNative();
    const backend = new MockBackend("apple", [ok("receipts", 0.9)]);
    const deps = testDeps(root, [backend], native);
    dropFixture("receipt.png", deps.cfg.inbox, "Screenshot old.png");
    const daemon = new Daemon(deps);
    daemon.start();
    await until(() => filed(join(deps.cfg.outputRoot, "receipts")).length === 1);
    await daemon.stop();
    expect(native.state.contextCalls).toBe(0);
    expect(backend.calls[0]!.appContext).toBeNull();
  });

  test("new arrivals don't requeue a failed file early or overwrite its context", async () => {
    const root = tempRoot();
    const native = fakeNative({ context: appContext({ bundleId: "com.later.App", appName: "Later" }) });
    const backend = new MockBackend("apple", [err("error", "down"), ok("code", 0.9)]);
    const deps = testDeps(root, [backend], native, { retryDelayMs: 60_000 });
    const failing = dropFixture("error.png", deps.cfg.inbox, "Screenshot first.png");
    const job = deps.store.createJob(failing, "Screenshot first.png", appContext({ bundleId: "com.first.App" }));
    const daemon = new Daemon(deps);
    daemon.start();
    await until(() => deps.store.getJob(job.id)?.status === "failed");
    dropFixture("code.png", deps.cfg.inbox, "Screenshot second.png");
    await until(() => filed(join(deps.cfg.outputRoot, "code")).length === 1);
    await daemon.stop();
    expect(backend.calls).toHaveLength(2);
    expect(backend.calls[1]!.appContext?.bundleId).toBe("com.later.App");
    expect(deps.store.getJob(job.id)).toMatchObject({ status: "failed", attempts: 1 });
    expect(JSON.parse(deps.store.getJob(job.id)!.context_json!).bundleId).toBe("com.first.App");
  });

  test("failed files are retried, then left in the inbox", async () => {
    const root = tempRoot();
    const backend = new MockBackend("apple", [err("error", "down"), err("error", "down"), ok("code", 0.9)]);
    const deps = testDeps(root, [backend], fakeNative(), { maxAttempts: 2 });
    const daemon = new Daemon(deps);
    daemon.start();
    const src = dropFixture("code.png", deps.cfg.inbox, "Screenshot flaky.png");
    await until(() => backend.calls.length >= 2);
    await new Promise((r) => setTimeout(r, 200));
    await daemon.stop();
    expect(backend.calls).toHaveLength(2);
    expect(existsSync(src)).toBe(true);
    expect(deps.store.latestJobForPath(src)).toMatchObject({ status: "failed", attempts: 2 });
  });
});
