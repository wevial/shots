import Foundation

// The two cloud backends run the user's own `claude` and `codex` CLIs in a locked-down,
// one-shot mode. Ported from src/classify/{cli,claudeCode,codex}.ts.

/// What one CLI run produced, before validation.
public enum RawReply: Sendable, Equatable {
    /// Reply text, plus the CLI's already-parsed structured output when it has one
    /// (claude's `structured_output`).
    case text(String, structured: JSONValue? = nil)
    case failure(FailureKind, message: String)
}

/// Runs `body` in a fresh temp directory holding only a copy of the image, named
/// `screenshot<ext>` (`.png` when the image has no extension). The directory is removed
/// afterwards, whatever happens. The CLI runs with this directory as its cwd.
public func withScratchDir<T>(
    imagePath: String,
    _ body: (_ dir: String, _ imageName: String) async throws -> T
) async throws -> T {
    let fm = FileManager.default
    let dir = Paths.join(NSTemporaryDirectory(), "shots-\(UUID().uuidString)")
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let ext = Paths.extname(imagePath).lowercased()
    let imageName = "screenshot\(ext.isEmpty ? ".png" : ext)"
    try fm.copyItem(atPath: imagePath, toPath: Paths.join(dir, imageName))
    return try await body(dir, imageName)
}

/// Runs a CLI backend once and validates the reply; on a bad reply, runs it once more with
/// a corrective message quoting the previous output. A second bad reply is `.invalid`.
/// `detail` is `after-retry` when the second run succeeded.
public func askWithRetry(prompt: String, _ ask: (_ prompt: String) async -> RawReply) async -> ClassifyOutcome {
    var current = prompt
    for attempt in 1...2 {
        let reply = await ask(current)
        guard case .text(let text, let structured) = reply else {
            if case .failure(let kind, let message) = reply { return .failure(kind, message: message) }
            return .failure(.error, message: "unreachable")
        }
        var errors: [String]
        do {
            let parsed = try structured ?? extractJson(text)
            switch validateResult(parsed) {
            case .valid(let result): return .success(result, detail: attempt > 1 ? "after-retry" : nil)
            case .invalid(let found): errors = found
            }
        } catch {
            errors = [errorMessage(error)]
        }
        if attempt == 2 {
            return .failure(.invalid, message: "invalid output after retry: \(errors.joined(separator: "; "))")
        }
        current = (
            [prompt, "", "Your previous reply was rejected:"]
            + errors.map { "- \($0)" }
            + ["Previous reply:", String(text.prefix(2000)), "",
               #"Reply again with ONLY a JSON object: {"category": string, "tags": string[], "title": string, "confidence": number}."#]
        ).joined(separator: "\n")
    }
    return .failure(.error, message: "unreachable")
}

/// Claude Code headless (`-p`): the exact argument list from src/classify/claudeCode.ts.
///   --restricted   drops Bash/code tools + WebFetch, confines file tools to cwd, ignores settings files
///   --safe-mode    no CLAUDE.md, skills, plugins, hooks, MCP, output styles
///   --tools Read + --allowed-tools Read(./image) + dontAsk: the one image is the only readable thing
public func claudeCodeArgs(_ config: CliBackendConfig, prompt: String, imageName: String, categories: [String]) -> [String] {
    [
        "-p", prompt,
        "--output-format", "json",
        "--json-schema", resultJsonSchema(categories: categories).serialized(),
        "--append-system-prompt", Prompt.instructions,
        "--tools", "Read",
        "--allowed-tools", "Read(./\(imageName))",
        "--restricted",
        "--safe-mode",
        "--strict-mcp-config",
        "--permission-mode", "dontAsk",
        "--permission-prompts", "none",
        "--no-session-persistence",
        "--model", config.model,
        "--effort", config.effort,
    ]
}

/// Reads `claude -p --output-format json` output: `is_error` → `.failure(.error)`,
/// otherwise `result` text plus `structured_output`. Non-JSON output is passed on as text.
public func parseClaudeOutput(_ stdout: String) -> RawReply {
    guard let parsed = try? JSONValue.parse(stdout), case .object(let out) = parsed else { return .text(stdout) }
    if out["is_error"]?.boolValue == true {
        let subtype = out["subtype"]?.stringValue ?? "error"
        let result = out["result"]?.stringValue ?? ""
        return .failure(.error, message: "claude: \(subtype): \(result.prefix(300))")
    }
    let structured = out["structured_output"].flatMap { $0.isNull ? nil : $0 }
    return .text(out["result"]?.stringValue ?? "", structured: structured)
}

/// `codex exec`: the exact argument list from src/classify/codex.ts.
///   --sandbox read-only, --ignore-user-config, --ignore-rules --ephemeral --skip-git-repo-check,
///   --disable memories/plugins/hooks, -i <image> (no tool needed to see it),
///   --output-schema (strict JSON), -o (final message to a file).
public func codexArgs(_ config: CliBackendConfig, prompt: String, dir: String, imageName: String) -> [String] {
    [
        "exec",
        "-m", config.model,
        "-c", "model_reasoning_effort=\"\(config.effort)\"",
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
        "-i", Paths.join(dir, imageName),
        "--output-schema", Paths.join(dir, "schema.json"),
        "-o", Paths.join(dir, "last-message.json"),
        prompt,
    ]
}

private func resolveBinary(_ config: CliBackendConfig, environment: [String: String]) -> String? {
    Exec.which(config.binary, path: environment["PATH"] ?? "")
}

public struct ClaudeCodeBackend: Backend {
    public let name = "claude-code"
    public let isCloud = true
    public var config: CliBackendConfig
    public var timeout: Duration

    public init(config: CliBackendConfig, timeout: Duration) {
        self.config = config
        self.timeout = timeout
    }

    public func classify(_ input: ClassifyInput) async -> ClassifyOutcome {
        let env = Exec.augmentedEnvironment()
        guard let binary = resolveBinary(config, environment: env) else {
            return .failure(.unavailable, message: "\(config.binary) not found on PATH")
        }
        do {
            return try await withScratchDir(imagePath: input.imagePath) { dir, imageName in
                let prompt = [
                    "Read the image file ./\(imageName) with the Read tool (it is the screenshot), then classify it.",
                    "Do not read or do anything else. Reply with only the JSON object.",
                    "",
                    Prompt.build(input, maxOcrChars: 8000),
                ].joined(separator: "\n")
                return await askWithRetry(prompt: prompt) { p in
                    let args = claudeCodeArgs(config, prompt: p, imageName: imageName, categories: input.categories)
                    let res = await Exec.run(binary, args, cwd: dir, timeout: timeout, environment: env)
                    if res.timedOut { return .failure(.timeout, message: "claude timed out after \(timeout.milliseconds)ms") }
                    if res.code != 0 && res.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let stderr = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        return .failure(.error, message: "claude exit \(res.code.map(String.init) ?? "null"): \(stderr.prefix(300))")
                    }
                    return parseClaudeOutput(res.stdout)
                }
            }
        } catch {
            return .failure(.error, message: errorMessage(error))
        }
    }
}

public struct CodexBackend: Backend {
    public let name = "codex"
    public let isCloud = true
    public var config: CliBackendConfig
    public var timeout: Duration

    public init(config: CliBackendConfig, timeout: Duration) {
        self.config = config
        self.timeout = timeout
    }

    public func classify(_ input: ClassifyInput) async -> ClassifyOutcome {
        let env = Exec.augmentedEnvironment()
        guard let binary = resolveBinary(config, environment: env) else {
            return .failure(.unavailable, message: "\(config.binary) not found on PATH")
        }
        do {
            return try await withScratchDir(imagePath: input.imagePath) { dir, imageName in
                try resultJsonSchema(categories: input.categories).serialized()
                    .write(toFile: Paths.join(dir, "schema.json"), atomically: false, encoding: .utf8)
                let prompt = [
                    Prompt.instructions,
                    "The attached image is the screenshot. Do not run any commands or read any files. Reply with only the JSON object.",
                    "",
                    Prompt.build(input, maxOcrChars: 8000),
                ].joined(separator: "\n")
                let lastPath = Paths.join(dir, "last-message.json")
                return await askWithRetry(prompt: prompt) { p in
                    try? FileManager.default.removeItem(atPath: lastPath)
                    let res = await Exec.run(
                        binary, codexArgs(config, prompt: p, dir: dir, imageName: imageName),
                        cwd: dir, timeout: timeout, environment: env)
                    if res.timedOut { return .failure(.timeout, message: "codex timed out after \(timeout.milliseconds)ms") }
                    let text = (try? String(contentsOfFile: lastPath, encoding: .utf8)) ?? ""
                    if res.code != 0 || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let lines = res.stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        let detail = lines.last { $0.localizedCaseInsensitiveContains("error") }
                            ?? res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                                .split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
                        return .failure(.error, message: "codex exit \(res.code.map(String.init) ?? "null"): \(detail.prefix(300))")
                    }
                    return .text(text)
                }
            }
        } catch {
            return .failure(.error, message: errorMessage(error))
        }
    }
}
