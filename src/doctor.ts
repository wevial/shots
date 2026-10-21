import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { Config } from "./config.ts";
import { Store } from "./db.ts";
import { run, which } from "./exec.ts";
import { helperNative, helperPath } from "./native.ts";

export const LAUNCHD_LABEL = "com.shots.agent";

type Check = { label: string; ok: boolean | null; detail: string };

/** parseAuth returns { ok, detail } from the auth command's combined output. */
async function cliCheck(name: string, bin: string, versionArgs: string[], authArgs: string[], parseAuth: (out: string, code: number | null) => { ok: boolean; detail: string }) {
  const path = which(bin);
  if (!path) return [{ label: `${name} CLI`, ok: false, detail: `${bin} not on PATH` }];
  const [ver, auth] = await Promise.all([run(path, versionArgs, { timeoutMs: 15_000 }), run(path, authArgs, { timeoutMs: 15_000 })]);
  return [
    { label: `${name} CLI`, ok: ver.code === 0, detail: `${ver.stdout.trim().split("\n")[0]} (${path})` },
    { label: `${name} auth`, ...parseAuth(`${auth.stdout}\n${auth.stderr}`.trim(), auth.code) },
  ];
}

export async function doctor(cfg: Config): Promise<{ checks: Check[]; ok: boolean }> {
  const checks: Check[] = [];
  const add = (label: string, ok: boolean | null, detail: string) => checks.push({ label, ok, detail });

  const sw = await run("sw_vers", ["-productVersion"]);
  add("macOS", true, sw.stdout.trim());

  const helper = helperPath();
  add("shots-helper", existsSync(helper), helper);
  if (existsSync(helper)) {
    try {
      const fm = await helperNative.fmStatus();
      add("Apple Intelligence model", fm.available, fm.available ? `available (context ${fm.contextSize} tokens)` : `unavailable: ${fm.reason}`);
      add("Apple image input", fm.imageInput.enabled ? true : null, fm.imageInput.enabled ? "enabled" : `text-only: ${fm.imageInput.reason}`);
    } catch (e) {
      add("Apple Intelligence model", false, (e as Error).message);
    }
    try {
      const p = await helperNative.permissions();
      // Informational: TCC attributes this to the terminal running doctor, not the daemon.
      add("Accessibility (this terminal)", p.accessibility ? true : null, p.accessibility ? "granted" : "not granted; the daemon's own grant is below");
      add("Screen Recording", p.screenRecording ? true : null, p.screenRecording ? "granted (window titles without AX)" : "not granted (optional)");
      for (const [app, s] of Object.entries(p.automation)) add(`Automation → ${app}`, s === "granted" ? true : null, s);
    } catch (e) {
      add("permissions", false, (e as Error).message);
    }
  }

  const statusFile = join(cfg.dataDir, "daemon-status.json");
  if (existsSync(statusFile)) {
    const st = JSON.parse(readFileSync(statusFile, "utf8"));
    const perms = st.permissions ?? {};
    add("daemon permissions", perms.accessibility ?? null,
      `as seen by the daemon at ${st.updatedAt}: accessibility=${perms.accessibility}, screenRecording=${perms.screenRecording}, binary=${st.execPath}`);
  } else {
    add("daemon permissions", null, "daemon has not run yet (no daemon-status.json)");
  }

  if (cfg.allowCloud) {
    if (cfg.backends.includes("claude-code")) {
      checks.push(...(await cliCheck("claude", cfg.claudeCode.binary, ["--version"], ["auth", "status"], (out) => {
        try {
          const s = JSON.parse(out.slice(out.indexOf("{"), out.lastIndexOf("}") + 1));
          return s.loggedIn
            ? { ok: true, detail: `logged in via ${s.authMethod} (${s.apiProvider}), model ${cfg.claudeCode.model}` }
            : { ok: false, detail: "not logged in (run `claude auth login`)" };
        } catch {
          return { ok: false, detail: "could not parse `claude auth status`" };
        }
      })));
    }
    if (cfg.backends.includes("codex")) {
      checks.push(...(await cliCheck("codex", cfg.codex.binary, ["--version"], ["login", "status"], (out, code) => {
        const line = out.split("\n").find((l) => /logged in/i.test(l));
        return code === 0 && line
          ? { ok: true, detail: `${line.trim()}, model ${cfg.codex.model}` }
          : { ok: false, detail: "not logged in (run `codex login`)" };
      })));
    }
  } else {
    add("cloud backends", null, "disabled (allowCloud=false)");
  }

  add("config backends", cfg.backends.length > 0, cfg.backends.join(" → ") + ` (escalate < ${cfg.escalateBelowConfidence}, review < ${cfg.reviewBelowConfidence})`);
  add("inbox", existsSync(cfg.inbox), cfg.inbox);
  const loc = await run("defaults", ["read", "com.apple.screencapture", "location"]);
  const location = loc.code === 0 ? resolve(loc.stdout.trim().replace(/^~/, homedir())) : null;
  add("screencapture location", location === resolve(cfg.inbox),
    location ? location : `unset (default Desktop); run: defaults write com.apple.screencapture location "${cfg.inbox}"`);
  const thumb = await run("defaults", ["read", "com.apple.screencapture", "show-thumbnail"]);
  add("floating thumbnail off", thumb.stdout.trim() === "0" ? true : null,
    thumb.stdout.trim() === "0" ? "off" : "on: files land ~5s late, so app context may describe the wrong app (defaults write com.apple.screencapture show-thumbnail -bool false)");

  const uid = process.getuid?.() ?? 501;
  const agent = await run("launchctl", ["print", `gui/${uid}/${LAUNCHD_LABEL}`]);
  const state = agent.stdout.match(/state = (\w+)/)?.[1];
  add("LaunchAgent", agent.code === 0 ? state === "running" : false, agent.code === 0 ? `loaded, state=${state}` : "not loaded (run scripts/install.sh)");

  try {
    const store = new Store(join(cfg.dataDir, "shots.db"));
    const s = store.stats();
    add("index", true, `${s.shots} shots, ${s.review} for review, jobs ${JSON.stringify(s.jobs)}, by backend ${s.byBackend.map((b) => `${b.backend}=${b.n}`).join(" ") || "-"}`);
    store.close();
  } catch (e) {
    add("index", false, (e as Error).message);
  }

  return { checks, ok: checks.every((c) => c.ok !== false) };
}

export function formatChecks(checks: Check[]): string {
  const width = Math.max(...checks.map((c) => c.label.length));
  return checks.map((c) => `${c.ok === true ? "✓" : c.ok === false ? "✗" : "•"} ${c.label.padEnd(width)}  ${c.detail}`).join("\n");
}
