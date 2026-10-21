import type { CliBackendConfig } from "../config.ts";
import { run, which } from "../exec.ts";
import { askWithRetry, type RawReply, withScratchDir } from "./cli.ts";
import { buildPrompt, INSTRUCTIONS } from "./prompt.ts";
import { resultJsonSchema } from "./schema.ts";
import type { Backend } from "./types.ts";

/**
 * Claude Code headless (`-p`). Scope, checked against `claude --help`:
 *   --restricted   drops Bash/code tools + WebFetch, confines file tools to cwd, ignores settings files
 *   --safe-mode    no CLAUDE.md, skills, plugins, hooks, MCP, output styles
 *   --tools Read + --allowed-tools Read(./screenshot.png) + --permission-mode dontAsk
 *                  + --permission-prompts none: the one image is the only readable thing
 *   --json-schema  structured output, returned as `structured_output`
 * Auth is whatever `claude` already uses (keychain / claude.ai login).
 */
export function claudeCodeArgs(cfg: CliBackendConfig, prompt: string, imageName: string, categories: string[]): string[] {
  return [
    "-p", prompt,
    "--output-format", "json",
    "--json-schema", JSON.stringify(resultJsonSchema(categories)),
    "--append-system-prompt", INSTRUCTIONS,
    "--tools", "Read",
    "--allowed-tools", `Read(./${imageName})`,
    "--restricted",
    "--safe-mode",
    "--strict-mcp-config",
    "--permission-mode", "dontAsk",
    "--permission-prompts", "none",
    "--no-session-persistence",
    "--model", cfg.model,
    "--effort", cfg.effort,
  ];
}

export function parseClaudeOutput(stdout: string): RawReply {
  let out: { is_error?: boolean; result?: string; structured_output?: unknown; subtype?: string };
  try {
    out = JSON.parse(stdout);
  } catch {
    return { ok: true, text: stdout };
  }
  if (out.is_error) return { ok: false, kind: "error", message: `claude: ${out.subtype ?? "error"}: ${String(out.result ?? "").slice(0, 300)}` };
  return { ok: true, text: String(out.result ?? ""), structured: out.structured_output ?? undefined };
}

export function claudeCodeBackend(cfg: CliBackendConfig, timeoutMs: number): Backend {
  return {
    name: "claude-code",
    cloud: true,
    async classify(input) {
      const bin = which(cfg.binary);
      if (!bin) return { ok: false, kind: "unavailable", message: `${cfg.binary} not found on PATH` };
      return withScratchDir(input.imagePath, (dir, imageName) => {
        const prompt = [
          `Read the image file ./${imageName} with the Read tool (it is the screenshot), then classify it.`,
          "Do not read or do anything else. Reply with only the JSON object.",
          "",
          buildPrompt(input, { maxOcrChars: 8000 }),
        ].join("\n");
        return askWithRetry(prompt, async (p) => {
          const res = await run(bin, claudeCodeArgs(cfg, p, imageName, input.categories), { cwd: dir, timeoutMs });
          if (res.timedOut) return { ok: false, kind: "timeout", message: `claude timed out after ${timeoutMs}ms` };
          if (res.code !== 0 && !res.stdout.trim()) return { ok: false, kind: "error", message: `claude exit ${res.code}: ${res.stderr.trim().slice(0, 300)}` };
          return parseClaudeOutput(res.stdout);
        });
      });
    },
  };
}
