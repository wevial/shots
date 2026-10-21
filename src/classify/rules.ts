import { normalizeTag } from "./schema.ts";
import type { Backend, ClassifyInput } from "./types.ts";

interface KeywordRule {
  category: string;
  pattern: RegExp;
}

const KEYWORD_RULES: KeywordRule[] = [
  { category: "errors", pattern: /\b(traceback|exception|stack trace|segmentation fault|panic:|fatal error|errno|uncaught|TypeError|ReferenceError)\b/i },
  { category: "receipts", pattern: /\b(receipt|order (number|#)|invoice|subtotal|amount paid|payment received)\b/i },
  { category: "finance", pattern: /\b(balance|account (number|ending)|transactions?|statement|portfolio|routing)\b/i },
  { category: "travel", pattern: /\b(boarding pass|flight|gate \w+|itinerary|check-in|reservation|departure)\b/i },
  { category: "code", pattern: /(\bfunction\b|\bconst\b|\bimport\b|=>|\bdef\b|\breturn\b|\{\s*$|;\s*$)/m },
];

/**
 * Local, deterministic fallback: app bundle ID first, then OCR keywords. Never leaves the
 * machine; the denylist path uses it when Apple's model is unavailable.
 */
export function rulesBackend(appRules: Record<string, string>): Backend {
  return {
    name: "rules",
    cloud: false,
    async classify(input) {
      const byApp = input.appContext?.bundleId ? appRules[input.appContext.bundleId] : undefined;
      const byKeyword = KEYWORD_RULES.find((r) => input.categories.includes(r.category) && r.pattern.test(input.ocrText));
      const category = byApp && input.categories.includes(byApp) ? byApp : byKeyword?.category ?? "misc";
      // App mapping is a decent signal, keywords a weak one; misc means "no idea".
      const confidence = byApp && category === byApp ? 0.7 : byKeyword ? 0.5 : 0.2;
      const tags = [input.appContext?.appName, category].filter((t): t is string => !!t).map(normalizeTag);
      return { ok: true, result: { category, tags: [...new Set(tags)], title: guessTitle(input), confidence } };
    },
  };
}

function guessTitle(input: ClassifyInput): string {
  const firstLine = input.ocrText.split("\n").map((l) => l.trim()).find((l) => l.length >= 4);
  const raw = input.appContext?.windowTitle || input.appContext?.urlTitle || firstLine || input.appContext?.appName || "screenshot";
  return raw.split(/\s+/).slice(0, 8).join(" ");
}
