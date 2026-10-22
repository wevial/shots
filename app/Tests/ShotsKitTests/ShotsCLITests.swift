import Foundation
import Testing
@testable import ShotsKit

struct ShotsCLITests {
    /// Writes an executable shell script standing in for `shots`.
    private func fakeCLI(_ body: String) throws -> ShotsCLI {
        let url = URL.temporaryDirectory.appending(path: "fake-shots-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return ShotsCLI(executable: url)
    }

    @Test func passesArgumentsAndReadsStdout() async throws {
        let cli = try fakeCLI(#"printf '%s|' "$@""#)
        let output = try await cli.run(["recat", "/tmp/a b.png", "--category", "code", "--json"])
        #expect(String(decoding: output, as: UTF8.self) == "recat|/tmp/a b.png|--category|code|--json|")
    }

    @Test func surfacesTheErrorLine() async throws {
        let cli = try fakeCLI("echo 'error: not in the index: x.png' >&2; exit 1")
        await #expect(throws: ShotsCLIError(message: "not in the index: x.png")) {
            _ = try await cli.recategorize(path: "x.png", to: "code")
        }
    }

    @Test func handlesLargeOutputOnBothPipes() async throws {
        // More than a pipe buffer (64 KB) on each stream must not deadlock.
        let cli = try fakeCLI("head -c 200000 /dev/zero | tr '\\\\0' a; head -c 200000 /dev/zero | tr '\\\\0' b >&2")
        let output = try await cli.run([])
        #expect(output.count == 200_000)
    }

    @Test func errorMessageFallsBackToFirstLine() {
        #expect(ShotsCLI.errorMessage(stderr: "recat needs a file\n\nshots — usage", status: 2) == "recat needs a file")
        #expect(ShotsCLI.errorMessage(stderr: "", status: 3) == "shots exited with status 3")
    }
}

extension ShotsCLITests {
    private static let recatJSON = #"""
    {"shot":{"id":4,"path":"/fixture/Screenshots/receipts/shot-4.png","original_name":"Screenshot 4.png","sha256":"sha-4","captured_at":"2026-10-21T09:00:00.000Z","processed_at":"2026-10-21T09:00:05.000Z","app_bundle_id":null,"app_name":null,"window_title":null,"url":null,"url_title":null,"capture_type":"selection","width":1440,"height":900,"ocr_text":"invoice number 1042","category":"receipts","suggested_category":null,"tags_json":"[\"invoice\"]","tags_text":"invoice","title":"Unclear screenshot","confidence":1,"backend":"manual","review":0,"attempts_json":null},"decision":{"final":{"category":"receipts","tags":["invoice"],"title":"Unclear screenshot","confidence":1},"backend":"manual","review":false,"suggestedCategory":null,"attempts":[]}}
    """#

    private func cli(printing body: String) throws -> ShotsCLI {
        let url = URL.temporaryDirectory.appending(path: "fake-shots-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return ShotsCLI(executable: url)
    }

    @Test func recategorizeDecodesRecatJSON() async throws {
        let json = Self.recatJSON
        let result = try await cli(printing: "cat <<'EOF'\n\(json)\nEOF").recategorize(path: "x.png", to: "receipts")
        #expect(result.shot.category == "receipts")
        #expect(result.shot.tags == ["invoice"])
        #expect(!result.shot.needsReview)
        #expect(result.decision.final.category == "receipts")
        #expect(result.decision.review == false)
    }

    @Test func rerunPassesBackendFlag() async throws {
        let json = Self.recatJSON
        // Fails unless the CLI got `--backend codex`.
        let script = "case \"$*\" in *'--backend codex'*) cat <<'EOF'\n\(json)\nEOF\n;; *) echo 'error: wrong args' >&2; exit 1;; esac"
        let result = try await cli(printing: script).rerun(path: "x.png", backend: .codex)
        #expect(result.shot.id == 4)
    }

    @Test func nonZeroExitCarriesTheMessage() async throws {
        let cli = try cli(printing: "echo 'error: boom' >&2; exit 1")
        do {
            _ = try await cli.rerun(path: "x.png", backend: .apple)
            Issue.record("expected a throw")
        } catch let error as ShotsCLIError {
            #expect(error.message == "boom")
            #expect(error.localizedDescription.contains("boom"))
        }
    }

    @Test func garbageStdoutThrowsInsteadOfCrashing() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await cli(printing: "echo not-json").recategorize(path: "x.png", to: "code")
        }
    }
}
