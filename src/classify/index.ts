import type { BackendName, Config } from "../config.ts";
import type { Native } from "../native.ts";
import { appleBackend } from "./apple.ts";
import { claudeCodeBackend } from "./claudeCode.ts";
import { codexBackend } from "./codex.ts";
import { rulesBackend } from "./rules.ts";
import type { Backend } from "./types.ts";

export function createBackend(name: BackendName, cfg: Config, native: Native): Backend {
  switch (name) {
    case "apple":
      return appleBackend(native, cfg.timeoutMs);
    case "claude-code":
      return claudeCodeBackend(cfg.claudeCode, cfg.timeoutMs);
    case "codex":
      return codexBackend(cfg.codex, cfg.timeoutMs);
    case "rules":
      return rulesBackend(cfg.appRules);
  }
}

export function createBackends(cfg: Config, native: Native): Backend[] {
  return cfg.backends.map((n) => createBackend(n, cfg, native));
}
