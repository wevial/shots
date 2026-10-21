import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

export const BACKEND_NAMES = ["apple", "claude-code", "codex", "rules"] as const;
export type BackendName = (typeof BACKEND_NAMES)[number];

export interface CliBackendConfig {
  /** Executable name or absolute path. Resolved against PATH at call time. */
  binary: string;
  model: string;
  effort: string;
}

export interface Config {
  inbox: string;
  outputRoot: string;
  categories: string[];
  /** Optional one-line description per category, included in every prompt. */
  categoryHints: Record<string, string>;
  backends: BackendName[];
  escalateBelowConfidence: number;
  /** Per-backend ceiling on self-reported confidence, for models that always say 0.9. */
  confidenceCap: Partial<Record<BackendName, number>>;
  /** Final results under this go to misc with a review flag. */
  reviewBelowConfidence: number;
  timeoutMs: number;
  allowCloud: boolean;
  /** Bundle IDs or app names (case-insensitive) whose screenshots never reach cloud backends. */
  cloudDenylist: string[];
  /** Hostnames (suffix match) whose browser screenshots never reach cloud backends. */
  cloudDenylistDomains: string[];
  /** When the frontmost app is unknown (no context captured), allow cloud backends anyway. */
  cloudWhenAppUnknown: boolean;
  /** bundleId -> category, used by the local "rules" backend. */
  appRules: Record<string, string>;
  copyToClipboard: boolean;
  /** Skip files whose metadata says they aren't screen captures. */
  requireScreenCapture: boolean;
  concurrency: number;
  maxAttempts: number;
  retryDelayMs: number;
  /** Files older than this at detection get no app context (it would describe the wrong moment). */
  contextMaxAgeMs: number;
  ocrLanguages: string[];
  claudeCode: CliBackendConfig;
  codex: CliBackendConfig;
  dataDir: string;
}

export const DEFAULT_CATEGORIES = [
  "code", "design", "ui-reference", "docs", "chat", "finance", "receipts",
  "shopping", "travel", "social", "errors", "misc",
];

/** One-line meaning per category; small on-device models lean on these heavily. */
export const DEFAULT_CATEGORY_HINTS: Record<string, string> = {
  code: "source code, terminals, diffs, pull requests, editors",
  design: "design tools and mockups (Figma, Sketch), color, typography, layout work",
  "ui-reference": "a product's or website's interface kept as reference: dashboards, screens, flows",
  docs: "documentation, articles, specs, reading material",
  chat: "a messaging conversation (Slack, Messages, Discord, email threads)",
  finance: "bank accounts, balances, investments, invoices to pay, budgets",
  receipts: "a receipt or order confirmation for a completed purchase",
  shopping: "product pages, carts, things to buy",
  travel: "flights, hotels, maps, itineraries, boarding passes",
  social: "social media posts and feeds",
  errors: "an error message, crash, stack trace, failing build",
  misc: "anything that fits nowhere else",
};

export function defaultConfig(home = homedir()): Config {
  return {
    inbox: join(home, "Screenshots/_inbox"),
    outputRoot: join(home, "Screenshots"),
    categories: [...DEFAULT_CATEGORIES],
    categoryHints: { ...DEFAULT_CATEGORY_HINTS },
    backends: ["apple", "claude-code", "codex"],
    escalateBelowConfidence: 0.6,
    confidenceCap: {},
    reviewBelowConfidence: 0.6,
    timeoutMs: 30000,
    allowCloud: true,
    cloudDenylist: [
      "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
      "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
      "com.apple.Passwords", "com.apple.keychainaccess",
    ],
    cloudDenylistDomains: [],
    cloudWhenAppUnknown: true,
    appRules: {
      "com.apple.dt.Xcode": "code",
      "com.microsoft.VSCode": "code",
      "com.todesktop.230313mzl4w4u92": "code",
      "com.apple.Terminal": "code",
      "com.googlecode.iterm2": "code",
      "com.mitchellh.ghostty": "code",
      "dev.zed.Zed": "code",
      "com.figma.Desktop": "design",
      "com.bohemiancoding.sketch3": "design",
      "com.tinyspeck.slackmacgap": "chat",
      "com.apple.MobileSMS": "chat",
      "com.hnc.Discord": "chat",
      "ru.keepcoder.Telegram": "chat",
      "net.whatsapp.WhatsApp": "chat",
    },
    copyToClipboard: true,
    requireScreenCapture: true,
    concurrency: 1,
    maxAttempts: 3,
    retryDelayMs: 5 * 60_000,
    contextMaxAgeMs: 15_000,
    ocrLanguages: [],
    claudeCode: { binary: "claude", model: "sonnet", effort: "low" },
    codex: { binary: "codex", model: "gpt-6-luna", effort: "low" },
    dataDir: join(home, ".local/share/shots"),
  };
}

export function configPath(): string {
  return process.env.SHOTS_CONFIG ?? join(homedir(), ".config/shots/config.json");
}

const expandHome = (p: string) => (p === "~" || p.startsWith("~/") ? join(homedir(), p.slice(1)) : p);

export class ConfigError extends Error {}

function check(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new ConfigError(`config: ${msg}`);
}

/** Shallow-merges user JSON over defaults (nested CLI backend objects merge one level deeper). */
export function mergeConfig(base: Config, user: Record<string, unknown>): Config {
  const merged = { ...base, ...user } as Config;
  merged.claudeCode = { ...base.claudeCode, ...(user.claudeCode as object | undefined) };
  merged.codex = { ...base.codex, ...(user.codex as object | undefined) };
  for (const k of ["inbox", "outputRoot", "dataDir"] as const) merged[k] = resolve(expandHome(merged[k]));
  validate(merged);
  return merged;
}

export function validate(c: Config): void {
  check(Array.isArray(c.categories) && c.categories.length > 0, "categories must be a non-empty array");
  check(c.categories.every((x) => typeof x === "string" && /^[a-z0-9][a-z0-9-]*$/.test(x)), "categories must be lowercase slugs");
  if (!c.categories.includes("misc")) c.categories.push("misc");
  check(Array.isArray(c.backends), "backends must be an array");
  for (const b of c.backends) check((BACKEND_NAMES as readonly string[]).includes(b), `unknown backend "${b}"`);
  for (const k of ["escalateBelowConfidence", "reviewBelowConfidence"] as const) {
    check(typeof c[k] === "number" && c[k] >= 0 && c[k] <= 1, `${k} must be 0-1`);
  }
  check(Number.isInteger(c.concurrency) && c.concurrency >= 1 && c.concurrency <= 2, "concurrency must be 1 or 2");
  check(c.timeoutMs > 0, "timeoutMs must be positive");
  check(resolve(c.inbox) !== resolve(c.outputRoot), "inbox and outputRoot must differ");
}

/** Loads config, writing the defaults on first run so the file is discoverable. */
export function loadConfig(path = configPath()): Config {
  const base = defaultConfig();
  if (!existsSync(path)) {
    mkdirSync(dirname(path), { recursive: true });
    const { dataDir: _, ...seed } = base;
    writeFileSync(path, JSON.stringify(seed, null, 2) + "\n");
    return mergeConfig(base, {});
  }
  let user: unknown;
  try {
    user = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    throw new ConfigError(`config: ${path} is not valid JSON: ${(e as Error).message}`);
  }
  check(user && typeof user === "object" && !Array.isArray(user), `${path} must hold a JSON object`);
  return mergeConfig(base, user as Record<string, unknown>);
}
