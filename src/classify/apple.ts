import type { Native } from "../native.ts";
import { buildPrompt, INSTRUCTIONS } from "./prompt.ts";
import { validateResult } from "./schema.ts";
import type { Backend } from "./types.ts";

/**
 * On-device Foundation Models via shots-helper. The helper decides text vs multimodal at
 * runtime (macOS 27 + vision capability), so this side always sends the image path.
 * The 4096-token context on macOS 26 is why OCR is clipped hard here.
 */
export function appleBackend(native: Native, timeoutMs: number): Backend {
  return {
    name: "apple",
    cloud: false,
    async classify(input) {
      const prompt = buildPrompt(input, { maxOcrChars: 4000 });
      const res = await native.fmClassify({ instructions: INSTRUCTIONS, prompt, imagePath: input.imagePath }, timeoutMs);
      if (res.kind === "unavailable") return { ok: false, kind: "unavailable", message: res.reason };
      if (res.kind === "error") {
        // A context overflow is worth one retry with less OCR.
        if (!res.message.includes("exceededContextWindowSize")) {
          return { ok: false, kind: res.message.includes("timed out") ? "timeout" : "error", message: res.message };
        }
        const shorter = buildPrompt(input, { maxOcrChars: 1200 });
        const retry = await native.fmClassify({ instructions: INSTRUCTIONS, prompt: shorter, imagePath: input.imagePath }, timeoutMs);
        if (retry.kind !== "ok") return { ok: false, kind: "error", message: retry.kind === "error" ? retry.message : retry.reason };
        return toOutcome(retry);
      }
      return toOutcome(res);
    },
  };
}

function toOutcome(res: { category: unknown; tags: unknown; title: unknown; confidence: unknown; mode: string }) {
  const v = validateResult(res);
  return v.ok
    ? { ok: true as const, result: v.value, detail: res.mode }
    : { ok: false as const, kind: "invalid" as const, message: v.errors.join("; ") };
}
