import type { ClassifyResult } from "./types.ts";

/** JSON Schema handed to the CLI backends. Codex's strict mode needs every key required and no extras. */
export function resultJsonSchema(categories: string[]) {
  return {
    type: "object",
    additionalProperties: false,
    required: ["category", "tags", "title", "confidence"],
    properties: {
      category: { type: "string", enum: categories },
      tags: { type: "array", items: { type: "string" }, maxItems: 8 },
      title: { type: "string" },
      confidence: { type: "number", minimum: 0, maximum: 1 },
    },
  };
}

/**
 * Pulls the first JSON object out of model text: strips ``` fences and any prose
 * before/after by scanning for a balanced top-level {...} (string-aware).
 */
export function extractJson(text: string): unknown {
  const trimmed = text.trim();
  try {
    return JSON.parse(trimmed);
  } catch {}
  const unfenced = trimmed.replace(/```(?:json)?\s*([\s\S]*?)```/i, "$1");
  for (let start = unfenced.indexOf("{"); start !== -1; start = unfenced.indexOf("{", start + 1)) {
    let depth = 0;
    let inString = false;
    for (let i = start; i < unfenced.length; i++) {
      const ch = unfenced[i];
      if (inString) {
        if (ch === "\\") i++;
        else if (ch === '"') inString = false;
      } else if (ch === '"') inString = true;
      else if (ch === "{") depth++;
      else if (ch === "}" && --depth === 0) {
        try {
          return JSON.parse(unfenced.slice(start, i + 1));
        } catch {
          break;
        }
      }
    }
  }
  throw new Error("no JSON object found in output");
}

export type Validation = { ok: true; value: ClassifyResult } | { ok: false; errors: string[] };

/**
 * Shape check only. An unknown category is still a valid shape: the chain maps it to misc + review.
 */
export function validateResult(raw: unknown): Validation {
  const errors: string[] = [];
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { ok: false, errors: ["expected a JSON object"] };
  const o = raw as Record<string, unknown>;
  if (typeof o.category !== "string" || !o.category.trim()) errors.push("category must be a non-empty string");
  if (!Array.isArray(o.tags) || !o.tags.every((t) => typeof t === "string")) errors.push("tags must be an array of strings");
  if (typeof o.title !== "string" || !o.title.trim()) errors.push("title must be a non-empty string");
  if (typeof o.confidence !== "number" || !Number.isFinite(o.confidence) || o.confidence < 0 || o.confidence > 1) {
    errors.push("confidence must be a number between 0 and 1");
  }
  if (errors.length) return { ok: false, errors };
  const tags = [...new Set((o.tags as string[]).map(normalizeTag).filter(Boolean))].slice(0, 8);
  return {
    ok: true,
    value: {
      category: (o.category as string).trim().toLowerCase(),
      tags,
      title: (o.title as string).trim(),
      confidence: o.confidence as number,
    },
  };
}

export const normalizeTag = (t: string) =>
  t.trim().toLowerCase().replace(/[\s_]+/g, "-").replace(/[^\p{L}\p{N}-]/gu, "").replace(/-+/g, "-").replace(/^-|-$/g, "").slice(0, 32);
