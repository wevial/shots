import { describe, expect, test } from "bun:test";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { claudeCodeArgs, claudeCodeBackend } from "../src/classify/claudeCode.ts";
import { codexArgs, codexBackend } from "../src/classify/codex.ts";
import type { ClassifyInput } from "../src/classify/types.ts";
import { defaultConfig } from "../src/config.ts";
import { appContext, FIXTURES, tempRoot } from "./helpers.ts";

const cfg = defaultConfig("/tmp/x");
const input: ClassifyInput = {
  imagePath: join(FIXTURES, "code.png"), ocrText: "const x = 1", appContext: appContext(), captureType: "selection",
  dimensions: { width: 1200, height: 600 }, categories: cfg.categories,
};

/**
 * Writes a fake CLI that logs its argv + cwd, then replies with the Nth canned stdout
 * (by call count) — enough to exercise wrapping, retry and timeouts without the real tools.
 */
function fakeCli(replies: string[], opts: { sleep?: number; lastMessageFile?: boolean } = {}) {
  const dir = tempRoot();
  const log = join(dir, "calls.jsonl");
  replies.forEach((r, i) => writeFileSync(join(dir, `reply-${i}`), r));
  const bin = join(dir, "fake-cli");
  writeFileSync(
    bin,
    `#!/usr/bin/env bun
const fs = require("node:fs");
const path = require("node:path");
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({ args, cwd: process.cwd(), files: fs.readdirSync(process.cwd()) }) + "\\n");
const n = fs.readFileSync(${JSON.stringify(log)}, "utf8").trim().split("\\n").length - 1;
const reply = fs.readFileSync(path.join(${JSON.stringify(dir)}, "reply-" + Math.min(n, ${replies.length - 1})), "utf8");
${opts.sleep ? `Bun.sleepSync(${opts.sleep});` : ""}
${opts.lastMessageFile ? `fs.writeFileSync(args[args.indexOf("-o") + 1], reply);` : `process.stdout.write(reply);`}
`,
  );
  chmodSync(bin, 0o755);
  const calls = () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l)) : []);
  return { bin, calls };
}

const claudeJson = (result: string, structured?: unknown) =>
  JSON.stringify({ type: "result", subtype: "success", is_error: false, result, ...(structured ? { structured_output: structured } : {}) });

describe("claude-code backend", () => {
  test("args lock the session down to reading one image", () => {
    const args = claudeCodeArgs(cfg.claudeCode, "PROMPT", "screenshot.png", ["code", "misc"]);
    for (const flag of ["-p", "--restricted", "--safe-mode", "--strict-mcp-config", "--no-session-persistence"]) expect(args).toContain(flag);
    expect(args[args.indexOf("--tools") + 1]).toBe("Read");
    expect(args[args.indexOf("--allowed-tools") + 1]).toBe("Read(./screenshot.png)");
    expect(args[args.indexOf("--permission-mode") + 1]).toBe("dontAsk");
    expect(args[args.indexOf("--permission-prompts") + 1]).toBe("none");
    expect(args[args.indexOf("--output-format") + 1]).toBe("json");
    expect(JSON.parse(args[args.indexOf("--json-schema") + 1]!).properties.category.enum).toEqual(["code", "misc"]);
    expect(args).not.toContain("--dangerously-skip-permissions");
  });

  test("uses structured_output, runs in a temp dir holding only the image copy", async () => {
    const fake = fakeCli([claudeJson("ignored", { category: "code", tags: ["ts"], title: "Snippet", confidence: 0.8 })]);
    const out = await claudeCodeBackend({ ...cfg.claudeCode, binary: fake.bin }, 5000).classify(input);
    expect(out).toEqual({ ok: true, result: { category: "code", tags: ["ts"], title: "Snippet", confidence: 0.8 }, detail: undefined });
    const [call] = fake.calls();
    expect(call.files).toEqual(["screenshot.png"]);
    expect(call.cwd).not.toContain(FIXTURES);
    expect(existsSync(call.cwd)).toBe(false); // cleaned up
  });

  test("strips prose/fences around JSON in `result`", async () => {
    const fake = fakeCli([claudeJson('Here it is:\n```json\n{"category":"errors","tags":[],"title":"Crash","confidence":0.7}\n```')]);
    const out = await claudeCodeBackend({ ...cfg.claudeCode, binary: fake.bin }, 5000).classify(input);
    expect(out.ok && out.result.category).toBe("errors");
  });

  test("one corrective retry, quoting the bad reply", async () => {
    const fake = fakeCli([claudeJson("I think it's code!"), claudeJson('{"category":"code","tags":[],"title":"Fixed","confidence":0.9}')]);
    const out = await claudeCodeBackend({ ...cfg.claudeCode, binary: fake.bin }, 5000).classify(input);
    expect(out).toMatchObject({ ok: true, detail: "after-retry" });
    const calls = fake.calls();
    expect(calls).toHaveLength(2);
    const retryPrompt: string = calls[1].args[calls[1].args.indexOf("-p") + 1];
    expect(retryPrompt).toContain("previous reply was rejected");
    expect(retryPrompt).toContain("I think it's code!");
  });

  test("fails after the retry is also invalid", async () => {
    const fake = fakeCli([claudeJson("nope"), claudeJson('{"category":"code"}')]);
    const out = await claudeCodeBackend({ ...cfg.claudeCode, binary: fake.bin }, 5000).classify(input);
    expect(out).toMatchObject({ ok: false, kind: "invalid" });
    expect(fake.calls()).toHaveLength(2);
  });

  test("is_error replies are errors, not retried", async () => {
    const fake = fakeCli([JSON.stringify({ is_error: true, subtype: "error_during_execution", result: "rate limited" })]);
    const out = await claudeCodeBackend({ ...cfg.claudeCode, binary: fake.bin }, 5000).classify(input);
    expect(out).toMatchObject({ ok: false, kind: "error" });
    expect(fake.calls()).toHaveLength(1);
  });

  test("timeout kills the process", async () => {
    const fake = fakeCli([claudeJson("{}")], { sleep: 3000 });
    const t = performance.now();
    const out = await claudeCodeBackend({ ...cfg.claudeCode, binary: fake.bin }, 300).classify(input);
    expect(out).toMatchObject({ ok: false, kind: "timeout" });
    expect(performance.now() - t).toBeLessThan(2500);
  });

  test("missing binary is 'unavailable'", async () => {
    const out = await claudeCodeBackend({ ...cfg.claudeCode, binary: "/nonexistent/claude" }, 1000).classify(input);
    expect(out).toMatchObject({ ok: false, kind: "unavailable" });
  });
});

describe("codex backend", () => {
  test("args: read-only sandbox, no user config, image attached, schema enforced", () => {
    const args = codexArgs(cfg.codex, "PROMPT", "/tmp/d", "screenshot.png");
    expect(args[0]).toBe("exec");
    expect(args[args.indexOf("--sandbox") + 1]).toBe("read-only");
    for (const flag of ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check"]) expect(args).toContain(flag);
    expect(args[args.indexOf("-i") + 1]).toBe("/tmp/d/screenshot.png");
    expect(args[args.indexOf("--output-schema") + 1]).toBe("/tmp/d/schema.json");
    expect(args[args.indexOf("-m") + 1]).toBe(cfg.codex.model);
    expect(args.at(-1)).toBe("PROMPT");
    expect(args).not.toContain("--dangerously-bypass-approvals-and-sandbox");
  });

  test("reads the -o last-message file and validates it", async () => {
    const fake = fakeCli(['{"category":"receipts","tags":["coffee"],"title":"Coffee receipt","confidence":0.95}'], { lastMessageFile: true });
    const out = await codexBackend({ ...cfg.codex, binary: fake.bin }, 5000).classify(input);
    expect(out.ok && out.result).toEqual({ category: "receipts", tags: ["coffee"], title: "Coffee receipt", confidence: 0.95 });
    expect(fake.calls()[0].files.sort()).toEqual(["schema.json", "screenshot.png"]);
  });

  test("retries once on invalid output", async () => {
    const fake = fakeCli(['{"category": 3}', '{"category":"code","tags":[],"title":"T","confidence":0.6}'], { lastMessageFile: true });
    const out = await codexBackend({ ...cfg.codex, binary: fake.bin }, 5000).classify(input);
    expect(out).toMatchObject({ ok: true, detail: "after-retry" });
  });
});
