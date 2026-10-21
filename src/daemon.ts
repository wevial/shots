import { existsSync, type FSWatcher, mkdirSync, readdirSync, watch, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { capturedAt, isCandidate, sha256File } from "./files.ts";
import { type Deps, processJob } from "./pipeline.ts";

/** Minimal FIFO with bounded concurrency; CLI backends are slow, so keep this at 1–2. */
export class AsyncQueue {
  private running = 0;
  private items: (() => Promise<void>)[] = [];
  private idleWaiters: (() => void)[] = [];

  constructor(private readonly concurrency: number) {}

  push(task: () => Promise<void>) {
    this.items.push(task);
    this.pump();
  }

  get size() {
    return this.items.length + this.running;
  }

  onIdle(): Promise<void> {
    return this.size === 0 ? Promise.resolve() : new Promise((r) => this.idleWaiters.push(r));
  }

  private pump() {
    while (this.running < this.concurrency && this.items.length) {
      const task = this.items.shift()!;
      this.running++;
      task()
        .catch(() => {})
        .finally(() => {
          this.running--;
          this.pump();
          if (this.size === 0) this.idleWaiters.splice(0).forEach((r) => r());
        });
    }
  }
}

type ScanMode = "event" | "scan" | "retry";

export class Daemon {
  readonly queue: AsyncQueue;
  private inflight = new Set<string>();
  private watcher: FSWatcher | null = null;
  private timers: ReturnType<typeof setInterval>[] = [];
  private retryTimers = new Set<ReturnType<typeof setTimeout>>();

  constructor(private readonly deps: Deps, private readonly opts: { rescanMs?: number } = {}) {
    this.queue = new AsyncQueue(deps.cfg.concurrency);
  }

  start() {
    const { cfg, store, log } = this.deps;
    mkdirSync(cfg.inbox, { recursive: true });
    const reset = store.resetInterrupted();
    if (reset) log.info("resumed interrupted jobs", { count: reset });
    for (const job of store.pendingJobs()) {
      if (!existsSync(job.inbox_path)) {
        store.finishJob(job.id, "failed", { error: "file disappeared before processing" });
        continue;
      }
      this.inflight.add(job.inbox_path);
      this.enqueue(job.id, job.inbox_path);
    }
    // Event filenames aren't trustworthy: Bun's watcher reports a rename under the *old* name
    // (macOS writes ".Screenshot…" then renames it). Any event just triggers a debounced rescan.
    this.watcher = watch(cfg.inbox, () => this.scheduleScan());
    this.watcher.on("error", (e) => log.error("watcher error", { error: String(e) }));
    void this.scan("retry");
    // FSEvents can coalesce or drop events (sleep/wake, bursts); a periodic scan is the safety net.
    this.timers.push(setInterval(() => void this.scan(), this.opts.rescanMs ?? 60_000));
    log.info("watching", { inbox: cfg.inbox, backends: cfg.backends, allowCloud: cfg.allowCloud, concurrency: cfg.concurrency });
  }

  async stop() {
    this.watcher?.close();
    if (this.scanTimer) clearTimeout(this.scanTimer);
    this.timers.forEach(clearInterval);
    this.retryTimers.forEach(clearTimeout);
    await this.queue.onIdle();
  }

  private scanTimer: ReturnType<typeof setTimeout> | null = null;

  private scheduleScan() {
    if (this.scanTimer) return;
    this.scanTimer = setTimeout(() => {
      this.scanTimer = null;
      void this.scan("event");
    }, 100);
  }

  async scan(mode: ScanMode = "scan") {
    let names: string[];
    try {
      names = readdirSync(this.deps.cfg.inbox);
    } catch {
      return;
    }
    await Promise.all(names.map((name) => this.detect(join(this.deps.cfg.inbox, name), mode)));
  }

  /**
   * One path, one decision. Modes:
   *   event  a watcher event just fired: capture live app context (before anything slow)
   *   scan   periodic safety net: new files only, no context (we can't know when they landed)
   *   retry  startup or retry timer: also re-queue failed files under maxAttempts
   */
  async detect(path: string, mode: ScanMode = "event"): Promise<void> {
    const { cfg, store, native, log } = this.deps;
    if (!isCandidate(path) || this.inflight.has(path) || !existsSync(path)) return;
    this.inflight.add(path);
    const drop = () => void this.inflight.delete(path);
    try {
      const age = Date.now() - capturedAt(path).getTime();
      const liveContext = mode === "event" && age <= cfg.contextMaxAgeMs;
      const contextPromise = liveContext ? native.context().catch(() => null) : Promise.resolve(null);
      const latest = store.latestJobForPath(path);
      if (latest?.status === "pending" || latest?.status === "processing") return this.enqueue(latest.id, path);

      const retryable = latest?.status === "failed" && latest.attempts < cfg.maxAttempts;
      if (latest && !(retryable && mode === "retry")) {
        // Already decided (or waiting on its retry timer). Only different bytes under the same name are new work.
        if (!latest.sha256 || latest.sha256 === sha256File(path)) return drop();
      }
      if (retryable && mode === "retry" && latest) {
        store.requeueJob(latest.id); // keeps the context captured when the file first landed
        log.info("retrying", { path, job: latest.id, attempt: latest.attempts + 1 });
        return this.enqueue(latest.id, path);
      }
      const ctx = await contextPromise;
      const job = store.createJob(path, basename(path), ctx);
      log.info("detected", { path, job: job.id, app: ctx?.bundleId ?? null, mode });
      this.enqueue(job.id, path);
    } catch (e) {
      drop();
      log.error("detect failed", { path, error: (e as Error).message });
    }
  }

  private enqueue(jobId: number, path: string) {
    this.queue.push(async () => {
      const result = await processJob(jobId, this.deps);
      this.inflight.delete(path);
      if (result.status === "failed" && result.retry) {
        const t = setTimeout(() => {
          this.retryTimers.delete(t);
          void this.detect(path, "retry");
        }, this.deps.cfg.retryDelayMs);
        this.retryTimers.add(t);
      }
    });
  }
}

export function writeDaemonStatus(dataDir: string, status: Record<string, unknown>) {
  mkdirSync(dataDir, { recursive: true });
  writeFileSync(join(dataDir, "daemon-status.json"), JSON.stringify({ ...status, updatedAt: new Date().toISOString() }, null, 2));
}
