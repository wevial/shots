import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { run } from "./exec.ts";

export interface AppContext {
  bundleId: string | null;
  appName: string | null;
  windowTitle: string | null;
  url: string | null;
  urlTitle: string | null;
  capturedAt: string;
  accessibility: boolean;
  notes: string[];
}

export interface ScreenshotMeta {
  isScreenCapture: boolean | null;
  captureType: string | null;
  source: "xattr" | "mdls" | "none";
}

export interface OcrResult {
  text: string;
  width: number;
  height: number;
}

export interface FmStatus {
  osVersion: string;
  available: boolean;
  reason?: string;
  imageInput: { enabled: boolean; reason: string };
  contextSize?: number;
}

export type FmClassifyResponse =
  | { kind: "ok"; category: unknown; tags: unknown; title: unknown; confidence: unknown; mode: string }
  | { kind: "unavailable"; reason: string }
  | { kind: "error"; message: string };

export interface Permissions {
  accessibility: boolean;
  screenRecording: boolean;
  automation: Record<string, string>;
}

/** Everything the daemon needs from macOS. Tests swap in a fake. */
export interface Native {
  meta(path: string): Promise<ScreenshotMeta>;
  context(): Promise<AppContext | null>;
  ocr(path: string, languages: string[]): Promise<OcrResult>;
  fmStatus(): Promise<FmStatus>;
  fmClassify(req: { instructions: string; prompt: string; imagePath: string }, timeoutMs: number): Promise<FmClassifyResponse>;
  setTags(path: string, tags: string[], remove?: string[]): Promise<void>;
  copyToClipboard(path: string): Promise<void>;
  permissions(): Promise<Permissions>;
}

export function helperPath(): string {
  if (process.env.SHOTS_HELPER) return process.env.SHOTS_HELPER;
  const candidates = [
    join(dirname(process.execPath), "shots-helper"), // next to the compiled `shots` binary
    join(import.meta.dir, "../native/.build/release/shots-helper"),
    join(import.meta.dir, "../native/.build/debug/shots-helper"),
  ];
  return candidates.find((c) => existsSync(c)) ?? candidates[1]!;
}

export class HelperError extends Error {}

async function callHelper(args: string[], opts: { stdin?: string; timeoutMs?: number } = {}) {
  const res = await run(helperPath(), args, { stdin: opts.stdin, timeoutMs: opts.timeoutMs ?? 30_000 });
  if (res.timedOut) throw new HelperError(`shots-helper ${args[0]} timed out`);
  let body: Record<string, unknown>;
  try {
    body = JSON.parse(res.stdout.trim().split("\n").pop() ?? "");
  } catch {
    throw new HelperError(`shots-helper ${args[0]} returned non-JSON (exit ${res.code}): ${res.stderr.trim() || res.stdout.trim()}`);
  }
  return { code: res.code, body };
}

async function helperOk(args: string[], opts?: { stdin?: string; timeoutMs?: number }) {
  const { code, body } = await callHelper(args, opts);
  if (code !== 0) throw new HelperError(String(body.error ?? `shots-helper ${args[0]} exit ${code}`));
  return body;
}

/** Spotlight fallback for files without the screencapture xattrs (e.g. copied without them). */
export async function mdlsMeta(path: string): Promise<ScreenshotMeta> {
  const res = await run("mdls", ["-raw", "-nullMarker", "", "-name", "kMDItemIsScreenCapture", "-name", "kMDItemScreenCaptureType", path], { timeoutMs: 5000 });
  if (res.code !== 0) return { isScreenCapture: null, captureType: null, source: "none" };
  const [isCap, type] = res.stdout.split("\0");
  if (!isCap && !type) return { isScreenCapture: null, captureType: null, source: "none" };
  return { isScreenCapture: isCap === "1", captureType: type || null, source: "mdls" };
}

export const helperNative: Native = {
  async meta(path) {
    const b = await helperOk(["meta", path]);
    if (b.source === "xattr") {
      return { isScreenCapture: (b.isScreenCapture as boolean) ?? null, captureType: (b.captureType as string) ?? null, source: "xattr" };
    }
    return mdlsMeta(path);
  },
  async context() {
    const b = await helperOk(["context"], { timeoutMs: 5000 });
    const app = b.app as { bundleId?: string; name?: string } | undefined;
    const browser = b.browser as { url?: string; title?: string } | undefined;
    return {
      bundleId: app?.bundleId || null,
      appName: app?.name || null,
      windowTitle: (b.windowTitle as string) ?? null,
      url: browser?.url || null,
      urlTitle: browser?.title || null,
      capturedAt: String(b.capturedAt),
      accessibility: Boolean(b.accessibility),
      notes: (b.notes as string[]) ?? [],
    };
  },
  async ocr(path, languages) {
    const b = await helperOk(languages.length ? ["ocr", path, languages.join(",")] : ["ocr", path], { timeoutMs: 60_000 });
    return { text: String(b.text ?? ""), width: Number(b.width), height: Number(b.height) };
  },
  async fmStatus() {
    return (await helperOk(["fm-status"])) as unknown as FmStatus;
  },
  async fmClassify(req, timeoutMs) {
    let res;
    try {
      res = await callHelper(["classify"], { stdin: JSON.stringify(req), timeoutMs });
    } catch (e) {
      return { kind: "error", message: (e as Error).message };
    }
    const { code, body } = res;
    if (code === 2) return { kind: "unavailable", reason: String(body.unavailable) };
    if (code !== 0) return { kind: "error", message: String(body.error) };
    return { kind: "ok", ...body, mode: String(body.mode) } as FmClassifyResponse;
  },
  async setTags(path, tags, remove = []) {
    await helperOk(remove.length ? ["tags", path, "--remove", remove.join(","), ...tags] : ["tags", path, ...tags]);
  },
  async copyToClipboard(path) {
    await helperOk(["clipboard", path]);
  },
  async permissions() {
    return (await helperOk(["permissions"])) as unknown as Permissions;
  },
};
