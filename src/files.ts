import { createHash } from "node:crypto";
import { copyFileSync, existsSync, linkSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync } from "node:fs";
import { basename, extname, join } from "node:path";

export const IMAGE_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".heic", ".tiff", ".tif", ".gif", ".bmp", ".webp"]);

/** macOS writes screenshots as hidden ".Screenshot …" temp files first, then renames them. */
export function isCandidate(path: string): boolean {
  const name = basename(path);
  return !name.startsWith(".") && IMAGE_EXTENSIONS.has(extname(name).toLowerCase());
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Resolves once size and mtime hold still for `stableChecks` consecutive polls. */
export async function waitForStable(path: string, opts: { intervalMs?: number; stableChecks?: number; timeoutMs?: number } = {}) {
  const { intervalMs = 250, stableChecks = 2, timeoutMs = 30_000 } = opts;
  const deadline = Date.now() + timeoutMs;
  let last = "";
  let stable = 0;
  while (Date.now() < deadline) {
    let sig: string;
    try {
      const s = statSync(path);
      sig = `${s.size}:${s.mtimeMs}`;
      if (s.size > 0 && sig === last) {
        if (++stable >= stableChecks) return s;
      } else stable = 0;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
      sig = "missing";
      stable = 0;
    }
    last = sig;
    await sleep(intervalMs);
  }
  throw new Error(`file never stabilised within ${timeoutMs}ms`);
}

export function sha256File(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

const pad = (n: number) => String(n).padStart(2, "0");

/** Local time, `YYYY-MM-DD_HHMM`. */
export function stamp(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}_${pad(d.getHours())}${pad(d.getMinutes())}`;
}

/** Lowercase, hyphenated, ASCII-ish, ≤ 60 chars; never empty. */
export function slugTitle(title: string): string {
  const slug = title
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60)
    .replace(/-+$/, "");
  return slug || "screenshot";
}

export function targetName(captured: Date, title: string, ext: string): string {
  return `${stamp(captured)}_${slugTitle(title)}${ext.toLowerCase()}`;
}

/** Picks `name`, or `name-2`, `name-3`… so existing files are never overwritten. */
export function uniquePath(dir: string, name: string, exclude?: string): string {
  const ext = extname(name);
  const stem = name.slice(0, name.length - ext.length);
  for (let i = 1; ; i++) {
    const candidate = join(dir, i === 1 ? name : `${stem}-${i}${ext}`);
    if (candidate === exclude || !existsSync(candidate)) return candidate;
  }
}

/**
 * Moves without ever overwriting and without a window where the file exists nowhere:
 * hard-link then unlink on the same volume, copy-verify-unlink across volumes.
 */
export function safeMove(src: string, dest: string): void {
  mkdirSync(join(dest, ".."), { recursive: true });
  if (src === dest) return;
  try {
    linkSync(src, dest); // fails with EEXIST instead of clobbering
    unlinkSync(src);
    return;
  } catch (e) {
    const code = (e as NodeJS.ErrnoException).code;
    if (code === "EEXIST") throw new Error(`destination exists: ${dest}`);
    if (code !== "EXDEV" && code !== "EPERM" && code !== "ENOTSUP") throw e;
  }
  if (existsSync(dest)) throw new Error(`destination exists: ${dest}`);
  try {
    renameSync(src, dest);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "EXDEV") throw e;
    copyFileSync(src, dest);
    if (statSync(dest).size !== statSync(src).size) {
      unlinkSync(dest);
      throw new Error("copy verification failed");
    }
    unlinkSync(src);
  }
}

/** Screenshot creation time: birthtime survives the hidden-temp-file rename macOS does. */
export function capturedAt(path: string): Date {
  const s = statSync(path);
  return s.birthtimeMs > 0 ? s.birthtime : s.mtime;
}
