import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { CliBackendConfig } from "../config.ts";
import { run, which } from "../exec.ts";
import { askWithRetry, withScratchDir } from "./cli.ts";
import { buildPrompt, INSTRUCTIONS } from "./prompt.ts";
import { resultJsonSchema } from "./schema.ts";
import type { Backend } from "./types.ts";

/**
 * Codex non-interactive (`codex exec`). Scope, checked against `codex exec --help`:
 *   --sandbox read-only      model-run commands can't write or reach the network
 *   --ignore-user-config     skip ~/.codex/config.toml (MCP servers, notify hooks); auth still from CODEX_HOME
 *   --ignore-rules --ephemeral --skip-git-repo-check, --disable memories/plugins/hooks
 *   -i <image>               image attached to the prompt (no tool needed to see it)
 *   --output-schema          strict JSON schema; -o writes the final message to a file
 * Model must be one your account accepts; not every model name works on every account type.
 */
export function codexArgs(cfg: CliBackendConfig, prompt: string, dir: string, imageName: string): string[] {
  return [
    "exec",
    "-m", cfg.model,
    "-c", `model_reasoning_effort="${cfg.effort}"`,
    "--sandbox", "read-only",
    "--ignore-user-config",
    "--ignore-rules",
    "--ephemeral",
    "--skip-git-repo-check",
    "--disable", "memories",
    "--disable", "plugins",
    "--disable", "hooks",
    "--color", "never",
    "-C", dir,
    "-i", join(dir, imageName),
    "--output-schema", join(dir, "schema.json"),
    "-o", join(dir, "last-message.json"),
    prompt,
  ];
}

export function codexBackend(cfg: CliBackendConfig, timeoutMs: number): Backend {
  return {
    name: "codex",
    cloud: true,
    async classify(input) {
      const bin = which(cfg.binary);
      if (!bin) return { ok: false, kind: "unavailable", message: `${cfg.binary} not found on PATH` };
      return withScratchDir(input.imagePath, (dir, imageName) => {
        writeFileSync(join(dir, "schema.json"), JSON.stringify(resultJsonSchema(input.categories)));
        const prompt = [
          INSTRUCTIONS,
          "The attached image is the screenshot. Do not run any commands or read any files. Reply with only the JSON object.",
          "",
          buildPrompt(input, { maxOcrChars: 8000 }),
        ].join("\n");
        return askWithRetry(prompt, async (p) => {
          const lastPath = join(dir, "last-message.json");
          rmSync(lastPath, { force: true });
          const res = await run(bin, codexArgs(cfg, p, dir, imageName), { cwd: dir, timeoutMs });
          if (res.timedOut) return { ok: false, kind: "timeout", message: `codex timed out after ${timeoutMs}ms` };
          const text = existsSync(lastPath) ? readFileSync(lastPath, "utf8") : "";
          if (res.code !== 0 || !text.trim()) {
            const err = res.stderr.split("\n").filter((l) => /error/i.test(l)).pop() ?? res.stderr.trim().split("\n").pop();
            return { ok: false, kind: "error", message: `codex exit ${res.code}: ${String(err ?? "").slice(0, 300)}` };
          }
          return { ok: true, text };
        });
      });
    },
  };
}
