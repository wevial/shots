import { copyFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import { extractJson, validateResult } from "./schema.ts";
import type { ClassifyOutcome } from "./types.ts";

export type RawReply =
  | { ok: true; text: string; structured?: unknown }
  | { ok: false; kind: "unavailable" | "error" | "timeout"; message: string };

/** Fresh temp dir holding only a copy of the image; the CLI runs with this as its cwd. */
export function withScratchDir<T>(imagePath: string, fn: (dir: string, imageName: string) => Promise<T>): Promise<T> {
  const dir = mkdtempSync(join(tmpdir(), "shots-"));
  const imageName = `screenshot${extname(imagePath).toLowerCase() || ".png"}`;
  copyFileSync(imagePath, join(dir, imageName));
  return fn(dir, imageName).finally(() => rmSync(dir, { recursive: true, force: true }));
}

/**
 * Runs a CLI backend once, validates, and on a bad reply runs it once more with a corrective
 * message quoting the previous output. A second bad reply is a failure.
 */
export async function askWithRetry(prompt: string, ask: (prompt: string) => Promise<RawReply>): Promise<ClassifyOutcome> {
  let current = prompt;
  for (let attempt = 1; attempt <= 2; attempt++) {
    const reply = await ask(current);
    if (!reply.ok) return reply;
    let parsed: unknown;
    let errors: string[];
    try {
      parsed = reply.structured ?? extractJson(reply.text);
      const v = validateResult(parsed);
      if (v.ok) return { ok: true, result: v.value, detail: attempt > 1 ? "after-retry" : undefined };
      errors = v.errors;
    } catch (e) {
      errors = [(e as Error).message];
    }
    if (attempt === 2) return { ok: false, kind: "invalid", message: `invalid output after retry: ${errors.join("; ")}` };
    current = [
      prompt,
      "",
      "Your previous reply was rejected:",
      ...errors.map((e) => `- ${e}`),
      "Previous reply:",
      reply.text.slice(0, 2000),
      "",
      'Reply again with ONLY a JSON object: {"category": string, "tags": string[], "title": string, "confidence": number}.',
    ].join("\n");
  }
  throw new Error("unreachable");
}
