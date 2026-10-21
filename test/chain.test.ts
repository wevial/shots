import { describe, expect, test } from "bun:test";
import { ChainError, privacyVerdict, runChain } from "../src/classify/chain.ts";
import { rulesBackend } from "../src/classify/rules.ts";
import type { ClassifyInput } from "../src/classify/types.ts";
import { defaultConfig } from "../src/config.ts";
import { appContext, err, MockBackend, ok } from "./helpers.ts";

const cfg = defaultConfig("/tmp/x");
const input: ClassifyInput = {
  imagePath: "/tmp/x.png", ocrText: "const x = 1;", appContext: appContext(), captureType: "selection",
  dimensions: { width: 10, height: 10 }, categories: cfg.categories,
};
const open = { cloudAllowed: true, reason: null };
const closed = { cloudAllowed: false, reason: "denylisted app com.1password.1password" };

describe("runChain", () => {
  test("stops at the first confident result", async () => {
    const a = new MockBackend("apple", [ok("code", 0.9)]);
    const b = new MockBackend("claude-code", [ok("docs", 0.95)], true);
    const d = await runChain(input, [a, b], cfg, open);
    expect(d.final.category).toBe("code");
    expect(d.backend).toBe("apple");
    expect(b.calls).toHaveLength(0);
  });

  test("escalates on low confidence and keeps the best", async () => {
    const a = new MockBackend("apple", [ok("code", 0.4)]);
    const b = new MockBackend("claude-code", [ok("errors", 0.8)], true);
    const d = await runChain(input, [a, b], cfg, open);
    expect(d).toMatchObject({ backend: "claude-code", review: false, final: { category: "errors" } });
    expect(d.attempts.map((x) => x.backend)).toEqual(["apple", "claude-code"]);
  });

  test("falls through errors, unavailability and timeouts", async () => {
    const a = new MockBackend("apple", [err("unavailable", "appleIntelligenceNotEnabled")]);
    const b = new MockBackend("claude-code", [err("timeout")], true);
    const c = new MockBackend("codex", [ok("receipts", 0.7)], true);
    const d = await runChain(input, [a, b, c], cfg, open);
    expect(d.backend).toBe("codex");
    expect(d.attempts.map((x) => (x.outcome.ok ? "ok" : x.outcome.kind))).toEqual(["unavailable", "timeout", "ok"]);
  });

  test("all low: best result wins but goes to misc for review", async () => {
    const a = new MockBackend("apple", [ok("code", 0.3)]);
    const b = new MockBackend("codex", [ok("design", 0.5)], true);
    const d = await runChain(input, [a, b], cfg, open);
    expect(d).toMatchObject({ backend: "codex", review: true, suggestedCategory: "design", final: { category: "misc", confidence: 0.5 } });
  });

  test("unknown category becomes misc + review even when confident", async () => {
    const d = await runChain(input, [new MockBackend("apple", [ok("memes", 0.99)])], cfg, open);
    expect(d).toMatchObject({ review: true, suggestedCategory: "memes", final: { category: "misc" } });
  });

  test("throws ChainError with every attempt when nothing succeeds", async () => {
    const a = new MockBackend("apple", [err("error", "boom")]);
    const promise = runChain(input, [a], cfg, open);
    await expect(promise).rejects.toBeInstanceOf(ChainError);
    await expect(promise).rejects.toThrow(/apple: error \(boom\)/);
  });

  test("a throwing backend counts as an error, not a crash", async () => {
    const a = { name: "apple", cloud: false, classify: async () => { throw new Error("helper crashed"); } };
    const b = new MockBackend("codex", [ok("code", 0.9)], true);
    expect((await runChain(input, [a, b], cfg, open)).backend).toBe("codex");
  });

  test("confidenceCap forces escalation past an overconfident backend", async () => {
    const a = new MockBackend("apple", [ok("code", 0.9)]);
    const b = new MockBackend("claude-code", [ok("design", 0.8)], true);
    const d = await runChain(input, [a, b], { ...cfg, confidenceCap: { apple: 0.55 } }, open);
    expect(d.backend).toBe("claude-code");
    const first = d.attempts[0]!.outcome;
    expect(first.ok && first.result.confidence).toBe(0.55);
  });
});

describe("privacy", () => {
  test("denylisted shots never reach cloud backends; rules fills in when apple is down", async () => {
    const apple = new MockBackend("apple", [err("unavailable", "modelNotReady")]);
    const cloud = new MockBackend("claude-code", [ok("code", 0.99)], true);
    const d = await runChain(input, [apple, cloud], cfg, closed, rulesBackend(cfg.appRules));
    expect(cloud.calls).toHaveLength(0);
    expect(d.backend).toBe("rules");
    expect(d.final.category).toBe("code"); // VS Code → code via appRules
    expect(d.attempts.find((a) => a.backend === "claude-code")?.outcome).toMatchObject({ kind: "skipped" });
  });

  test("denylisted + apple available: apple only", async () => {
    const apple = new MockBackend("apple", [ok("finance", 0.8)]);
    const cloud = new MockBackend("codex", [ok("code", 0.99)], true);
    const d = await runChain(input, [apple, cloud], cfg, closed, rulesBackend(cfg.appRules));
    expect(d.backend).toBe("apple");
    expect(cloud.calls).toHaveLength(0);
  });

  test("privacyVerdict", () => {
    const pw = appContext({ bundleId: "com.1password.1password", appName: "1Password" });
    expect(privacyVerdict(cfg, pw).cloudAllowed).toBe(false);
    expect(privacyVerdict({ ...cfg, cloudDenylist: ["Chase"] }, appContext({ bundleId: "com.chase", appName: "chase" })).cloudAllowed).toBe(false);
    expect(privacyVerdict({ ...cfg, allowCloud: false }, appContext())).toEqual({ cloudAllowed: false, reason: "allowCloud=false" });
    const bank = appContext({ bundleId: "com.google.Chrome", appName: "Chrome", url: "https://secure.chase.com/web/auth" });
    expect(privacyVerdict({ ...cfg, cloudDenylistDomains: ["chase.com"] }, bank).cloudAllowed).toBe(false);
    expect(privacyVerdict({ ...cfg, cloudDenylistDomains: ["chase.com"] }, appContext({ url: "https://notchase.com" })).cloudAllowed).toBe(true);
    expect(privacyVerdict({ ...cfg, cloudWhenAppUnknown: false }, null).cloudAllowed).toBe(false);
    expect(privacyVerdict(cfg, null).cloudAllowed).toBe(true);
  });
});

describe("rules backend", () => {
  const rules = rulesBackend(cfg.appRules);
  test("app mapping beats keywords", async () => {
    const out = await rules.classify({ ...input, ocrText: "Traceback (most recent call last)" });
    expect(out.ok && out.result).toMatchObject({ category: "code", confidence: 0.7 });
  });
  test("keywords when the app is unknown", async () => {
    const out = await rules.classify({ ...input, appContext: null, ocrText: "Traceback (most recent call last):\nValueError" });
    expect(out.ok && out.result).toMatchObject({ category: "errors", confidence: 0.5 });
  });
  test("misc with low confidence when nothing matches", async () => {
    const out = await rules.classify({ ...input, appContext: null, ocrText: "lorem ipsum" });
    expect(out.ok && out.result).toMatchObject({ category: "misc", confidence: 0.2 });
  });
});
