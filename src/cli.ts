#!/usr/bin/env bun
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { createBackend, createBackends } from "./classify/index.ts";
import { rulesBackend } from "./classify/rules.ts";
import { BACKEND_NAMES, type BackendName, type Config, ConfigError, configPath, loadConfig } from "./config.ts";
import { Daemon, writeDaemonStatus } from "./daemon.ts";
import { Store } from "./db.ts";
import { doctor, formatChecks } from "./doctor.ts";
import { createLogger } from "./log.ts";
import { type Deps, recat } from "./pipeline.ts";
import { helperNative, helperPath } from "./native.ts";

const USAGE = `shots — auto-organize macOS screenshots

  shots run                         watch the inbox (what the LaunchAgent runs)
  shots search <query> [--limit N]  full-text search over OCR, titles, tags, app, URL
  shots recat <file> [--backend <${BACKEND_NAMES.join("|")}>] [--category <name>]
                                    re-classify and re-file an indexed screenshot
  shots review [--failed]           list low-confidence / unknown-category shots (or failed jobs)
  shots doctor                      check OS, models, CLIs, auth, permissions, config
  shots config                      print the effective config and its path
`;

function makeDeps(cfg: Config): Deps {
  return {
    cfg,
    store: new Store(join(cfg.dataDir, "shots.db")),
    native: helperNative,
    backends: createBackends(cfg, helperNative),
    rules: rulesBackend(cfg.appRules),
    log: createLogger(),
  };
}

const short = (p: string) => p.replace(process.env.HOME ?? "\0", "~");

async function main(argv: string[]): Promise<number> {
  const [command, ...rest] = argv;
  if (!command || command === "help" || command === "--help" || command === "-h") {
    process.stdout.write(USAGE);
    return command ? 0 : 1;
  }
  const cfg = loadConfig();

  switch (command) {
    case "run": {
      const deps = makeDeps(cfg);
      const permissions = await helperNative.permissions().catch((e) => ({ error: String(e) }));
      const fm = await helperNative.fmStatus().catch((e) => ({ error: String(e) }));
      writeDaemonStatus(cfg.dataDir, { pid: process.pid, execPath: process.execPath, helper: helperPath(), permissions, fm });
      deps.log.info("starting", { config: configPath(), helper: helperPath(), permissions, fm });
      const daemon = new Daemon(deps);
      daemon.start();
      const shutdown = async (sig: string) => {
        deps.log.info("stopping", { signal: sig, queued: daemon.queue.size });
        await Promise.race([daemon.stop(), new Promise((r) => setTimeout(r, 10_000))]);
        deps.store.close();
        process.exit(0);
      };
      process.on("SIGTERM", () => void shutdown("SIGTERM"));
      process.on("SIGINT", () => void shutdown("SIGINT"));
      await new Promise(() => {});
      return 0;
    }

    case "search": {
      const { values, positionals } = parseArgs({ args: rest, allowPositionals: true, options: { limit: { type: "string", default: "20" }, json: { type: "boolean" } } });
      const query = positionals.join(" ");
      if (!query) throw new UsageError("search needs a query");
      const store = new Store(join(cfg.dataDir, "shots.db"));
      const rows = store.search(query, Number(values.limit));
      if (values.json) console.log(JSON.stringify(rows.map(({ ocr_text, ...r }) => r), null, 2));
      else if (!rows.length) console.log("no matches");
      else
        for (const r of rows) {
          console.log(`${r.captured_at.slice(0, 16).replace("T", " ")}  [${r.category}]  ${r.title}`);
          console.log(`    ${short(r.path)}`);
          const meta = [r.app_name, r.url].filter(Boolean).join(" · ");
          if (meta) console.log(`    ${meta}`);
          if (r.snippet?.trim()) console.log(`    ${r.snippet.replace(/\s+/g, " ").slice(0, 160)}`);
        }
      return 0;
    }

    case "recat": {
      const { values, positionals } = parseArgs({ args: rest, allowPositionals: true, options: { backend: { type: "string" }, category: { type: "string" } } });
      const ref = positionals[0];
      if (!ref) throw new UsageError("recat needs a file");
      const deps = makeDeps(cfg);
      const shot = deps.store.findShot(ref, resolve(ref));
      if (!shot) throw new UsageError(`not in the index: ${ref}`);
      let backends;
      if (values.backend) {
        if (!(BACKEND_NAMES as readonly string[]).includes(values.backend)) throw new UsageError(`unknown backend "${values.backend}"`);
        backends = [createBackend(values.backend as BackendName, cfg, helperNative)];
      }
      const { shot: updated, decision } = await recat(shot, { backends, category: values.category }, deps);
      console.log(`${short(shot.path)}\n  → ${short(updated.path)}`);
      console.log(`  ${decision.final.category} (${decision.final.confidence.toFixed(2)} via ${decision.backend})${decision.review ? `, review (suggested: ${decision.suggestedCategory ?? "none"})` : ""}`);
      for (const a of decision.attempts) console.log(`  ${a.backend}: ${a.outcome.ok ? `ok ${a.outcome.result.category} ${a.outcome.result.confidence}` : `${a.outcome.kind}: ${a.outcome.message}`} (${a.ms}ms)`);
      return 0;
    }

    case "review": {
      const { values } = parseArgs({ args: rest, options: { failed: { type: "boolean" } } });
      const store = new Store(join(cfg.dataDir, "shots.db"));
      if (values.failed) {
        const jobs = store.failedJobs();
        if (!jobs.length) console.log("no failed jobs");
        for (const j of jobs) console.log(`${j.updated_at.slice(0, 16)}  attempts=${j.attempts}  ${short(j.inbox_path)}\n    ${j.last_error}`);
        return 0;
      }
      const rows = store.reviewQueue();
      if (!rows.length) console.log("nothing to review");
      for (const r of rows) {
        console.log(`${r.captured_at.slice(0, 16).replace("T", " ")}  suggested=${r.suggested_category ?? "-"}  conf=${r.confidence.toFixed(2)}  via ${r.backend}`);
        console.log(`    ${short(r.path)}  "${r.title}"`);
      }
      if (rows.length) console.log(`\nfix with: shots recat <file> --category <name>   or   shots recat <file> --backend claude-code`);
      return 0;
    }

    case "doctor": {
      const { checks, ok } = await doctor(cfg);
      console.log(formatChecks(checks));
      return ok ? 0 : 1;
    }

    case "config":
      console.log(`# ${configPath()}`);
      console.log(JSON.stringify(cfg, null, 2));
      return 0;

    default:
      throw new UsageError(`unknown command "${command}"`);
  }
}

class UsageError extends Error {}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (e) => {
    if (e instanceof UsageError) process.stderr.write(`${e.message}\n\n${USAGE}`);
    else if (e instanceof ConfigError) process.stderr.write(`${e.message}\n`);
    else process.stderr.write(`error: ${(e as Error).message}\n`);
    process.exit(e instanceof UsageError ? 2 : 1);
  },
);
