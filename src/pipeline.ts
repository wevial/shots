import { existsSync } from "node:fs";
import { basename, extname, join } from "node:path";
import { type ChainDecision, decide, privacyVerdict, runChain } from "./classify/chain.ts";
import type { Backend, ClassifyInput } from "./classify/types.ts";
import type { Config } from "./config.ts";
import type { ShotRow, Store } from "./db.ts";
import { capturedAt, safeMove, sha256File, targetName, uniquePath, waitForStable } from "./files.ts";
import type { Logger } from "./log.ts";
import type { AppContext, Native } from "./native.ts";

export interface Deps {
  cfg: Config;
  store: Store;
  native: Native;
  backends: Backend[];
  /** Local fallback used when cloud is off for a shot. */
  rules: Backend;
  log: Logger;
  stableOpts?: Parameters<typeof waitForStable>[1];
}

export type JobResult =
  | { status: "done"; shot: ShotRow }
  | { status: "skipped"; reason: string }
  | { status: "failed"; error: string; retry: boolean };

export const REVIEW_TAG = "review";

export function finderTags(decision: ChainDecision): string[] {
  return [...new Set([decision.final.category, ...decision.final.tags, ...(decision.review ? [REVIEW_TAG] : [])])];
}

export async function processJob(jobId: number, deps: Deps): Promise<JobResult> {
  const { cfg, store, native, log } = deps;
  const job = store.startJob(jobId);
  const path = job.inbox_path;
  const fail = (error: string): JobResult => {
    store.finishJob(job.id, "failed", { error });
    const retry = job.attempts < cfg.maxAttempts && existsSync(path);
    log.error("job failed; file left in inbox", { path, error, attempt: job.attempts, retry });
    return { status: "failed", error, retry };
  };
  const skip = (reason: string, sha?: string): JobResult => {
    store.finishJob(job.id, "skipped", { error: reason, sha256: sha });
    log.info("skipped", { path, reason });
    return { status: "skipped", reason };
  };

  try {
    await waitForStable(path, deps.stableOpts);
    const sha = sha256File(path);
    const dup = store.shotBySha(sha);
    if (dup) return skip(`duplicate of ${dup.path}`, sha);
    const prior = store.skippedJobForSha(sha, job.id);
    if (prior) return skip(prior.last_error ?? "previously skipped", sha);

    const meta = await native.meta(path);
    if (cfg.requireScreenCapture && meta.isScreenCapture !== true) {
      return skip(`not a screen capture (metadata source: ${meta.source})`, sha);
    }

    const ocr = await native.ocr(path, cfg.ocrLanguages);
    const ctx = job.context_json ? (JSON.parse(job.context_json) as AppContext) : null;
    const input: ClassifyInput = {
      imagePath: path,
      ocrText: ocr.text,
      appContext: ctx,
      captureType: meta.captureType,
      dimensions: { width: ocr.width, height: ocr.height },
      categories: cfg.categories,
      categoryHints: cfg.categoryHints,
    };
    const privacy = privacyVerdict(cfg, ctx);
    const decision = await runChain(input, deps.backends, cfg, privacy, deps.rules);
    const captured = capturedAt(path);
    const dest = uniquePath(join(cfg.outputRoot, decision.final.category), targetName(captured, decision.final.title, extname(path)));

    // Row first, then move: a failed insert (e.g. a racing duplicate) leaves the file untouched.
    const shot = store.insertShot({
      path: dest,
      original_name: basename(path),
      sha256: sha,
      captured_at: captured.toISOString(),
      processed_at: new Date().toISOString(),
      app_bundle_id: ctx?.bundleId ?? null,
      app_name: ctx?.appName ?? null,
      window_title: ctx?.windowTitle ?? null,
      url: ctx?.url ?? null,
      url_title: ctx?.urlTitle ?? null,
      capture_type: meta.captureType,
      width: ocr.width,
      height: ocr.height,
      ocr_text: ocr.text,
      category: decision.final.category,
      suggested_category: decision.suggestedCategory,
      tags_json: JSON.stringify(decision.final.tags),
      title: decision.final.title,
      confidence: decision.final.confidence,
      backend: decision.backend,
      review: decision.review ? 1 : 0,
      attempts_json: JSON.stringify(decision.attempts),
    });
    try {
      safeMove(path, dest);
    } catch (e) {
      store.db.run("delete from shots where id = ?", [shot.id]);
      throw e;
    }
    await applySideEffects(dest, finderTags(decision), [], deps);
    store.finishJob(job.id, "done", { sha256: sha, shotId: shot.id });
    log.info("filed", {
      from: basename(path), to: dest, backend: decision.backend, confidence: decision.final.confidence,
      review: decision.review, privacy: privacy.reason, attempts: decision.attempts.map((a) => `${a.backend}:${a.outcome.ok ? "ok" : a.outcome.kind}`),
    });
    return { status: "done", shot };
  } catch (e) {
    return fail((e as Error).message);
  }
}

/** Tags and clipboard are best-effort: the file is already filed and indexed. */
async function applySideEffects(dest: string, tags: string[], removeTags: string[], deps: Deps, clipboard = deps.cfg.copyToClipboard) {
  try {
    await deps.native.setTags(dest, tags, removeTags);
  } catch (e) {
    deps.log.warn("finder tags failed", { dest, error: (e as Error).message });
  }
  if (clipboard) {
    try {
      await deps.native.copyToClipboard(dest);
    } catch (e) {
      deps.log.warn("clipboard copy failed", { dest, error: (e as Error).message });
    }
  }
}

export function shotContext(shot: ShotRow): AppContext | null {
  if (!shot.app_bundle_id && !shot.app_name) return null;
  return {
    bundleId: shot.app_bundle_id, appName: shot.app_name, windowTitle: shot.window_title, url: shot.url,
    urlTitle: shot.url_title, capturedAt: shot.captured_at, accessibility: false, notes: [],
  };
}

export interface RecatOptions {
  /** Use only this backend instead of the configured chain. */
  backends?: Backend[];
  /** Skip classification and file under this category. */
  category?: string;
}

/** Re-classifies an indexed shot from its stored OCR + context, then renames/moves/retags it. */
export async function recat(shot: ShotRow, opts: RecatOptions, deps: Deps): Promise<{ shot: ShotRow; decision: ChainDecision }> {
  const { cfg, store } = deps;
  if (!existsSync(shot.path)) throw new Error(`file is gone: ${shot.path}`);
  const ctx = shotContext(shot);
  const oldTags = [shot.category, ...(JSON.parse(shot.tags_json) as string[]), REVIEW_TAG];

  let decision: ChainDecision;
  if (opts.category) {
    if (!cfg.categories.includes(opts.category)) throw new Error(`unknown category "${opts.category}" (have: ${cfg.categories.join(", ")})`);
    decision = decide({ category: opts.category, tags: JSON.parse(shot.tags_json), title: shot.title, confidence: 1 }, "manual", cfg);
  } else {
    const backends = opts.backends ?? deps.backends;
    const privacy = privacyVerdict(cfg, ctx);
    // An explicit --backend that privacy rules forbid is an error, not a silent skip.
    const blocked = opts.backends?.filter((b) => b.cloud && !privacy.cloudAllowed) ?? [];
    if (blocked.length) throw new Error(`refusing to send to ${blocked.map((b) => b.name).join(", ")}: ${privacy.reason}`);
    const input: ClassifyInput = {
      imagePath: shot.path,
      ocrText: shot.ocr_text,
      appContext: ctx,
      captureType: shot.capture_type,
      dimensions: shot.width && shot.height ? { width: shot.width, height: shot.height } : null,
      categories: cfg.categories,
      categoryHints: cfg.categoryHints,
    };
    decision = await runChain(input, backends, cfg, privacy, deps.rules);
  }

  const dest = uniquePath(
    join(cfg.outputRoot, decision.final.category),
    targetName(new Date(shot.captured_at), decision.final.title, extname(shot.path)),
    shot.path,
  );
  safeMove(shot.path, dest);
  const updated = store.updateShot(shot.id, {
    path: dest,
    category: decision.final.category,
    suggested_category: decision.suggestedCategory,
    tags_json: JSON.stringify(decision.final.tags),
    title: decision.final.title,
    confidence: decision.final.confidence,
    backend: decision.backend,
    review: decision.review ? 1 : 0,
    attempts_json: JSON.stringify(decision.attempts),
    processed_at: new Date().toISOString(),
  });
  await applySideEffects(dest, finderTags(decision), oldTags, deps, false);
  return { shot: updated, decision };
}
