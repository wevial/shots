import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rulesBackend } from "../src/classify/rules.ts";
import type { Backend, ClassifyInput, ClassifyOutcome } from "../src/classify/types.ts";
import { type Config, defaultConfig, mergeConfig } from "../src/config.ts";
import { Store } from "../src/db.ts";
import { silentLogger } from "../src/log.ts";
import type { AppContext, Native } from "../src/native.ts";
import type { Deps } from "../src/pipeline.ts";

export const FIXTURES = join(import.meta.dir, "fixtures");

/** Backend that replays scripted outcomes (last one repeats) and records every input. */
export class MockBackend implements Backend {
  calls: ClassifyInput[] = [];
  active = 0;
  maxActive = 0;

  constructor(
    readonly name: string,
    private script: (ClassifyOutcome | ((input: ClassifyInput) => ClassifyOutcome))[],
    readonly cloud = false,
    private delayMs = 0,
  ) {}

  async classify(input: ClassifyInput): Promise<ClassifyOutcome> {
    this.calls.push(input);
    this.active++;
    this.maxActive = Math.max(this.maxActive, this.active);
    try {
      if (this.delayMs) await new Promise((r) => setTimeout(r, this.delayMs));
      const step = this.script[Math.min(this.calls.length - 1, this.script.length - 1)]!;
      return typeof step === "function" ? step(input) : step;
    } finally {
      this.active--;
    }
  }
}

export const ok = (category: string, confidence: number, title = `${category} shot`, tags: string[] = [category]): ClassifyOutcome => ({
  ok: true,
  result: { category, confidence, title, tags },
});
export const err = (kind: "unavailable" | "error" | "timeout" | "invalid", message: string = kind): ClassifyOutcome => ({ ok: false, kind, message });

export interface FakeNativeState {
  tags: Map<string, string[]>;
  clipboard: string[];
  contextCalls: number;
}

export function fakeNative(opts: { context?: AppContext | null; isScreenCapture?: boolean | null; ocrText?: string; ocrFails?: boolean } = {}): Native & { state: FakeNativeState } {
  const state: FakeNativeState = { tags: new Map(), clipboard: [], contextCalls: 0 };
  return {
    state,
    async meta() {
      const v = opts.isScreenCapture === undefined ? true : opts.isScreenCapture;
      return { isScreenCapture: v, captureType: v ? "selection" : null, source: v === null ? "none" : "xattr" };
    },
    async context() {
      state.contextCalls++;
      return opts.context === undefined ? appContext() : opts.context;
    },
    async ocr() {
      if (opts.ocrFails) throw new Error("ocr exploded");
      return { text: opts.ocrText ?? "hello world from a screenshot", width: 800, height: 600 };
    },
    async fmStatus() {
      return { osVersion: "26.0.0", available: true, imageInput: { enabled: false, reason: "test" } };
    },
    async fmClassify() {
      return { kind: "unavailable", reason: "test" };
    },
    async setTags(path, tags, remove = []) {
      const existing = (state.tags.get(path) ?? []).filter((t) => !remove.includes(t));
      state.tags.set(path, [...new Set([...existing, ...tags])]);
    },
    async copyToClipboard(path) {
      state.clipboard.push(path);
    },
    async permissions() {
      return { accessibility: true, screenRecording: false, automation: {} };
    },
  };
}

export function appContext(over: Partial<AppContext> = {}): AppContext {
  return {
    bundleId: "com.microsoft.VSCode", appName: "Code", windowTitle: "config.ts — shots", url: null, urlTitle: null,
    capturedAt: new Date().toISOString(), accessibility: true, notes: [], ...over,
  };
}

export function tempRoot(): string {
  return mkdtempSync(join(tmpdir(), "shots-test-"));
}

export function testConfig(root: string, over: Partial<Config> = {}): Config {
  return mergeConfig(defaultConfig(root), {
    inbox: join(root, "inbox"),
    outputRoot: join(root, "out"),
    dataDir: join(root, "data"),
    retryDelayMs: 50,
    ...over,
  });
}

export function testDeps(root: string, backends: Backend[], native: Native, over: Partial<Config> = {}): Deps {
  const cfg = testConfig(root, over);
  mkdirSync(cfg.inbox, { recursive: true });
  return {
    cfg,
    store: new Store(join(cfg.dataDir, "shots.db")),
    native,
    backends,
    rules: rulesBackend(cfg.appRules),
    log: silentLogger,
    stableOpts: { intervalMs: 10, stableChecks: 2, timeoutMs: 2000 },
  };
}

/** Copies a fixture into a directory under a screenshot-like name. */
export function dropFixture(fixture: string, dir: string, name: string): string {
  mkdirSync(dir, { recursive: true });
  const dest = join(dir, name);
  copyFileSync(join(FIXTURES, fixture), dest);
  return dest;
}

/** Writes the xattrs macOS's screencapture adds, so the real helper sees a screenshot. */
export function markAsScreenshot(path: string, type = "selection") {
  const bplist = (xml: string) => execFileSync("plutil", ["-convert", "binary1", "-o", "-", "-"], { input: xml }).toString("hex");
  const wrap = (v: string) => `<?xml version="1.0"?><plist version="1.0">${v}</plist>`;
  execFileSync("xattr", ["-wx", "com.apple.metadata:kMDItemIsScreenCapture", bplist(wrap("<true/>")), path]);
  execFileSync("xattr", ["-wx", "com.apple.metadata:kMDItemScreenCaptureType", bplist(wrap(`<string>${type}</string>`)), path]);
}

export async function until(cond: () => boolean, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() > deadline) throw new Error("timed out waiting for condition");
    await new Promise((r) => setTimeout(r, 20));
  }
}
