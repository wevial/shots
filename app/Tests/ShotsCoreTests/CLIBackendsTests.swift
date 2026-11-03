import Foundation
import Testing
@testable import ShotsCore

// Ported from test/cliBackends.test.ts. The "CLIs" are a small shell script that records each
// call (NUL-separated argv, cwd, directory listing) and replies with the Nth canned output.

private struct FakeCall {
    var args: [String]
    var cwd: String
    var files: [String]
}

private struct FakeCli {
    var bin: String
    var dir: String

    /// - Parameters:
    ///   - sleep: seconds to sleep before replying.
    ///   - lastMessageFile: write the reply to the file after `-o` (codex) instead of stdout.
    init(_ replies: [String], sleep: Int = 0, lastMessageFile: Bool = false) throws {
        dir = try tempRoot()
        try FileManager.default.createDirectory(atPath: Paths.join(dir, "calls"), withIntermediateDirectories: true)
        for (i, reply) in replies.enumerated() {
            try reply.write(toFile: Paths.join(dir, "reply-\(i)"), atomically: true, encoding: .utf8)
        }
        try "replies=\(replies.count)\nsleep=\(sleep)\nlast=\(lastMessageFile ? 1 : 0)\n"
            .write(toFile: Paths.join(dir, "settings"), atomically: true, encoding: .utf8)
        bin = Paths.join(dir, "fake-cli")
        try FileManager.default.createSymbolicLink(atPath: bin, withDestinationPath: try Self.script.get())
    }

    /// One script for every fake, reached through a symlink in each fake's folder. macOS
    /// checks a newly written executable on its first run, one at a time: with a fresh script
    /// per test, a few tests in parallel queued for seconds and hit their timeouts.
    private static let script = Result { () throws -> String in
        let path = Paths.join(try tempRoot(), "fake-cli")
        let source = #"""
            #!/bin/sh
            dir=${0%/*}
            . "$dir/settings"
            n=$(ls "$dir/calls" | grep -c '\.cwd$')
            printf '%s\0' "$@" > "$dir/calls/$n.args"
            pwd -P > "$dir/calls/$n.cwd"
            ls -A > "$dir/calls/$n.files"
            i=$n
            if [ "$i" -gt $((replies - 1)) ]; then i=$((replies - 1)); fi
            if [ "$sleep" -gt 0 ]; then sleep "$sleep"; fi
            if [ "$last" = 1 ]; then
              out=""; prev=""
              for a in "$@"; do if [ "$prev" = "-o" ]; then out="$a"; fi; prev="$a"; done
              cat "$dir/reply-$i" > "$out"
            else
              cat "$dir/reply-$i"
            fi
            """#
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    var calls: [FakeCall] {
        var result: [FakeCall] = []
        var n = 0
        while let argData = FileManager.default.contents(atPath: Paths.join(dir, "calls/\(n).args")) {
            let args = String(decoding: argData, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
            let cwd = (try? String(contentsOfFile: Paths.join(dir, "calls/\(n).cwd"), encoding: .utf8))?.trimmingCharacters(in: .newlines) ?? ""
            let files = ((try? String(contentsOfFile: Paths.join(dir, "calls/\(n).files"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            result.append(FakeCall(args: args, cwd: cwd, files: files))
            n += 1
        }
        return result
    }
}

private let config = Config.defaults(home: "/tmp/x")

private var input: ClassifyInput {
    ClassifyInput(
        imagePath: Fixtures.path("code.png"), ocrText: "const x = 1", appContext: appContext(), captureType: "selection",
        dimensions: .init(width: 1200, height: 600), categories: config.categories
    )
}

private func claudeJSON(_ result: String, structured: String? = nil) -> String {
    var fields = "\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\(JSONValue.string(result).serialized())"
    if let structured { fields += ",\"structured_output\":\(structured)" }
    return "{\(fields)}"
}

private func value(after flag: String, in args: [String]) -> String? {
    args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}

private func claude(_ cli: FakeCli, timeout: Duration = .seconds(5)) -> ClaudeCodeBackend {
    var cfg = config.claudeCode
    cfg.binary = cli.bin
    return ClaudeCodeBackend(config: cfg, timeout: timeout)
}

private func codex(_ cli: FakeCli, timeout: Duration = .seconds(5)) -> CodexBackend {
    var cfg = config.codex
    cfg.binary = cli.bin
    return CodexBackend(config: cfg, timeout: timeout)
}

struct ClaudeCodeBackendTests {
    @Test func argsLockTheSessionDownToReadingOneImage() throws {
        let args = claudeCodeArgs(config.claudeCode, prompt: "PROMPT", imageName: "screenshot.png", categories: ["code", "misc"])
        for flag in ["-p", "--restricted", "--safe-mode", "--strict-mcp-config", "--no-session-persistence"] {
            #expect(args.contains(flag), "missing \(flag)")
        }
        #expect(value(after: "--tools", in: args) == "Read")
        #expect(value(after: "--allowed-tools", in: args) == "Read(./screenshot.png)")
        #expect(value(after: "--permission-mode", in: args) == "dontAsk")
        #expect(value(after: "--permission-prompts", in: args) == "none")
        #expect(value(after: "--output-format", in: args) == "json")
        let schema = try JSONValue.parse(try #require(value(after: "--json-schema", in: args)))
        let categories = schema["properties"]?["category"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(categories == ["code", "misc"])
        #expect(!args.contains("--dangerously-skip-permissions"))
    }

    @Test func usesStructuredOutputInATempDirHoldingOnlyTheImageCopy() async throws {
        let cli = try FakeCli([claudeJSON("ignored", structured: #"{"category":"code","tags":["ts"],"title":"Snippet","confidence":0.8}"#)])
        let outcome = await claude(cli).classify(input)
        #expect(outcome == .success(ClassifyResult(category: "code", tags: ["ts"], title: "Snippet", confidence: 0.8)))
        let call = try #require(cli.calls.first)
        #expect(call.files == ["screenshot.png"])
        #expect(!call.cwd.contains(Fixtures.directory))
        #expect(!FileManager.default.fileExists(atPath: call.cwd)) // cleaned up
    }

    @Test func stripsProseAndFencesAroundJSONInResult() async throws {
        let cli = try FakeCli([claudeJSON("Here it is:\n```json\n{\"category\":\"errors\",\"tags\":[],\"title\":\"Crash\",\"confidence\":0.7}\n```")])
        let outcome = await claude(cli).classify(input)
        #expect(outcome.result?.category == "errors")
    }

    @Test func oneCorrectiveRetryQuotingTheBadReply() async throws {
        let cli = try FakeCli([
            claudeJSON("I think it's code!"),
            claudeJSON(#"{"category":"code","tags":[],"title":"Fixed","confidence":0.9}"#),
        ])
        let outcome = await claude(cli).classify(input)
        #expect(outcome == .success(ClassifyResult(category: "code", tags: [], title: "Fixed", confidence: 0.9), detail: "after-retry"))
        let calls = cli.calls
        #expect(calls.count == 2)
        let retryPrompt = try #require(value(after: "-p", in: calls[1].args))
        #expect(retryPrompt.contains("previous reply was rejected"))
        #expect(retryPrompt.contains("I think it's code!"))
    }

    @Test func failsAfterTheRetryIsAlsoInvalid() async throws {
        let cli = try FakeCli([claudeJSON("nope"), claudeJSON(#"{"category":"code"}"#)])
        let outcome = await claude(cli).classify(input)
        guard case .failure(.invalid, _) = outcome else { Issue.record("expected invalid, got \(outcome)"); return }
        #expect(cli.calls.count == 2)
    }

    @Test func isErrorRepliesAreErrorsNotRetried() async throws {
        let cli = try FakeCli([#"{"is_error":true,"subtype":"error_during_execution","result":"rate limited"}"#])
        let outcome = await claude(cli).classify(input)
        guard case .failure(.error, _) = outcome else { Issue.record("expected error, got \(outcome)"); return }
        #expect(cli.calls.count == 1)
    }

    @Test func timeoutKillsTheProcess() async throws {
        let cli = try FakeCli([claudeJSON("{}")], sleep: 3)
        let start = ContinuousClock.now
        let outcome = await claude(cli, timeout: .milliseconds(300)).classify(input)
        guard case .failure(.timeout, _) = outcome else { Issue.record("expected timeout, got \(outcome)"); return }
        #expect(ContinuousClock.now - start < .milliseconds(2500))
    }

    @Test func missingBinaryIsUnavailable() async throws {
        var cfg = config.claudeCode
        cfg.binary = "/nonexistent/claude"
        let outcome = await ClaudeCodeBackend(config: cfg, timeout: .seconds(1)).classify(input)
        guard case .failure(.unavailable, _) = outcome else { Issue.record("expected unavailable, got \(outcome)"); return }
    }

    @Test func parseClaudeOutputShapes() {
        #expect(parseClaudeOutput(#"{"is_error":true,"subtype":"x","result":"boom"}"#) != .text("", structured: nil))
        if case .failure(.error, let message) = parseClaudeOutput(#"{"is_error":true,"subtype":"x","result":"boom"}"#) {
            #expect(message.hasPrefix("claude: x: boom"))
        } else {
            Issue.record("expected an error reply")
        }
        #expect(parseClaudeOutput("not json") == .text("not json"))
    }
}

struct CodexBackendTests {
    @Test func argsReadOnlySandboxNoUserConfigImageAttachedSchemaEnforced() {
        let args = codexArgs(config.codex, prompt: "PROMPT", dir: "/tmp/d", imageName: "screenshot.png")
        #expect(args.first == "exec")
        #expect(value(after: "--sandbox", in: args) == "read-only")
        for flag in ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check"] {
            #expect(args.contains(flag), "missing \(flag)")
        }
        #expect(value(after: "-i", in: args) == "/tmp/d/screenshot.png")
        #expect(value(after: "--output-schema", in: args) == "/tmp/d/schema.json")
        #expect(value(after: "-m", in: args) == config.codex.model)
        #expect(args.last == "PROMPT")
        #expect(!args.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    @Test func readsTheLastMessageFileAndValidatesIt() async throws {
        let cli = try FakeCli([#"{"category":"receipts","tags":["coffee"],"title":"Coffee receipt","confidence":0.95}"#], lastMessageFile: true)
        let outcome = await codex(cli).classify(input)
        #expect(outcome.result == ClassifyResult(category: "receipts", tags: ["coffee"], title: "Coffee receipt", confidence: 0.95))
        #expect(try #require(cli.calls.first).files.sorted() == ["schema.json", "screenshot.png"])
    }

    @Test func retriesOnceOnInvalidOutput() async throws {
        let cli = try FakeCli(
            [#"{"category": 3}"#, #"{"category":"code","tags":[],"title":"T","confidence":0.6}"#], lastMessageFile: true
        )
        let outcome = await codex(cli).classify(input)
        #expect(outcome == .success(ClassifyResult(category: "code", tags: [], title: "T", confidence: 0.6), detail: "after-retry"))
        #expect(cli.calls.count == 2)
    }
}
