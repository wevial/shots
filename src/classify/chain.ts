import type { Config } from "../config.ts";
import type { AppContext } from "../native.ts";
import type { Backend, ClassifyInput, ClassifyOutcome, ClassifyResult } from "./types.ts";

export interface Attempt {
  backend: string;
  ms: number;
  outcome: ClassifyOutcome | { ok: false; kind: "skipped"; message: string };
}

export interface ChainDecision {
  /** What gets applied: category is always one of config.categories. */
  final: ClassifyResult;
  backend: string;
  review: boolean;
  /** The model's own category when the decision overrode it to misc. */
  suggestedCategory: string | null;
  attempts: Attempt[];
}

export class ChainError extends Error {
  constructor(message: string, readonly attempts: Attempt[]) {
    super(message);
  }
}

export interface PrivacyVerdict {
  cloudAllowed: boolean;
  reason: string | null;
}

const hostOf = (url: string) => {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return null;
  }
};

export function privacyVerdict(cfg: Pick<Config, "allowCloud" | "cloudDenylist" | "cloudDenylistDomains" | "cloudWhenAppUnknown">, ctx: AppContext | null): PrivacyVerdict {
  if (!cfg.allowCloud) return { cloudAllowed: false, reason: "allowCloud=false" };
  if (!ctx?.bundleId && !ctx?.appName) {
    return cfg.cloudWhenAppUnknown ? { cloudAllowed: true, reason: null } : { cloudAllowed: false, reason: "app unknown" };
  }
  const deny = cfg.cloudDenylist.map((d) => d.toLowerCase());
  if (ctx.bundleId && deny.includes(ctx.bundleId.toLowerCase())) return { cloudAllowed: false, reason: `denylisted app ${ctx.bundleId}` };
  if (ctx.appName && deny.includes(ctx.appName.toLowerCase())) return { cloudAllowed: false, reason: `denylisted app ${ctx.appName}` };
  const host = ctx.url ? hostOf(ctx.url) : null;
  if (host) {
    const hit = cfg.cloudDenylistDomains.map((d) => d.toLowerCase().replace(/^\*?\./, "")).find((d) => host === d || host.endsWith("." + d));
    if (hit) return { cloudAllowed: false, reason: `denylisted domain ${hit}` };
  }
  return { cloudAllowed: true, reason: null };
}

/**
 * Walks the ordered backends. Stops at the first result at/above escalateBelowConfidence;
 * otherwise keeps the most confident result seen. When cloud is off for this shot, the
 * local "rules" backend is appended as a last resort so denylisted shots still get filed.
 */
export async function runChain(
  input: ClassifyInput,
  backends: Backend[],
  cfg: Pick<Config, "escalateBelowConfidence" | "reviewBelowConfidence" | "categories"> & Partial<Pick<Config, "confidenceCap">>,
  privacy: PrivacyVerdict,
  rules?: Backend,
): Promise<ChainDecision> {
  const attempts: Attempt[] = [];
  const ordered = [...backends];
  if (!privacy.cloudAllowed && rules && !ordered.some((b) => b.name === rules.name)) ordered.push(rules);

  let best: { result: ClassifyResult; backend: string } | null = null;
  for (const backend of ordered) {
    if (backend.cloud && !privacy.cloudAllowed) {
      attempts.push({ backend: backend.name, ms: 0, outcome: { ok: false, kind: "skipped", message: privacy.reason ?? "cloud disabled" } });
      continue;
    }
    const started = performance.now();
    let outcome: ClassifyOutcome;
    try {
      outcome = await backend.classify(input);
    } catch (e) {
      outcome = { ok: false, kind: "error", message: (e as Error).message };
    }
    const cap = cfg.confidenceCap?.[backend.name as keyof Config["confidenceCap"]];
    if (outcome.ok && cap !== undefined && outcome.result.confidence > cap) {
      outcome = { ...outcome, result: { ...outcome.result, confidence: cap }, detail: [outcome.detail, `capped from ${outcome.result.confidence}`].filter(Boolean).join(", ") };
    }
    attempts.push({ backend: backend.name, ms: Math.round(performance.now() - started), outcome });
    if (!outcome.ok) continue;
    if (!best || outcome.result.confidence > best.result.confidence) best = { result: outcome.result, backend: backend.name };
    if (outcome.result.confidence >= cfg.escalateBelowConfidence) break;
  }

  if (!best) {
    const summary = attempts.map((a) => `${a.backend}: ${a.outcome.ok ? "ok" : `${a.outcome.kind} (${a.outcome.message})`}`).join("; ");
    throw new ChainError(`all backends failed: ${summary || "no backends configured"}`, attempts);
  }
  return decide(best.result, best.backend, cfg, attempts);
}

export function decide(
  result: ClassifyResult,
  backend: string,
  cfg: Pick<Config, "reviewBelowConfidence" | "categories">,
  attempts: Attempt[] = [],
): ChainDecision {
  const known = cfg.categories.includes(result.category);
  const confident = result.confidence >= cfg.reviewBelowConfidence;
  if (known && confident) return { final: result, backend, review: false, suggestedCategory: null, attempts };
  return {
    final: { ...result, category: "misc" },
    backend,
    review: true,
    suggestedCategory: result.category === "misc" ? null : result.category,
    attempts,
  };
}
