import Foundation
import Testing
@testable import ShotsCore

// Ported from test/pipeline.test.ts.

private let name = "Screenshot 2026-10-21 at 10.22.28 AM.png"

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

private func filedShot(_ result: JobResult) throws -> ShotRow {
    guard case .done(let shot) = result else { throw ShotsError("expected done, got \(result)") }
    return shot
}

@Suite struct ProcessJobTests {
    @Test func filesRenamesTagsCopiesAndIndexes() async throws {
        let root = try tempRoot()
        let native = FakeNative(ocrText: "export function loadConfig(path: string) {}")
        let backend = MockBackend("apple", [ok("code", 0.9, title: "Load config function", tags: ["typescript", "config"])])
        let deps = try testDeps(root, backends: [backend], native: native)
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let job = try await deps.database.createJob(path: src, originalName: name, context: appContext())

        let shot = try filedShot(await processJob(job.id, deps: deps))
        #expect(!exists(src))
        let dir = Paths.join(deps.config.outputRoot, "code")
        #expect(shot.path.wholeMatch(of: /.*\/\d{4}-\d{2}-\d{2}_\d{4}_load-config-function\.png/) != nil)
        #expect(Paths.dirname(shot.path) == dir)
        #expect(exists(shot.path))
        #expect(native.tags[shot.path] == ["code", "typescript", "config"])
        #expect(native.clipboard == [src]) // copied from the inbox, before filing
        #expect(shot.originalName == name)
        #expect(shot.backend == "apple")
        #expect(shot.appBundleId == "com.microsoft.VSCode")
        #expect(shot.windowTitle == "config.ts — shots")
        #expect(shot.review == false)
        #expect(shot.captureType == "selection")
        #expect(shot.width == 800 && shot.height == 600)
        #expect(backend.calls.first?.appContext?.bundleId == "com.microsoft.VSCode")
        #expect(try await deps.database.job(id: job.id)?.status == .done)
        #expect(try await deps.database.job(id: job.id)?.shotId == shot.id)

        #expect(try await deps.database.search("loadconfig").map(\.shot.id) == [shot.id])
        #expect(try await deps.database.search("typescript").count == 1)
        #expect(try await deps.database.search("shots").count == 1) // window title
    }

    @Test func sameBytesTwiceSkipsTheSecond() async throws {
        let root = try tempRoot()
        let backend = MockBackend("apple", [ok("code", 0.9)])
        let deps = try testDeps(root, backends: [backend], native: FakeNative())
        let a = try Fixtures.drop("code.png", into: deps.config.inbox, as: "a.png")
        _ = await processJob(try await deps.database.createJob(path: a, originalName: "a.png", context: nil).id, deps: deps)
        let b = try Fixtures.drop("code.png", into: deps.config.inbox, as: "b.png")
        let job = try await deps.database.createJob(path: b, originalName: "b.png", context: nil)
        let result = await processJob(job.id, deps: deps)
        guard case .skipped(let reason) = result else { Issue.record("expected skipped, got \(result)"); return }
        #expect(reason.hasPrefix("duplicate of "))
        #expect(exists(b))
        #expect(backend.calls.count == 1)
        #expect(try await deps.database.job(id: job.id)?.sha256 != nil)
    }

    @Test func nonScreenshotsAreSkippedAndRemembered() async throws {
        let root = try tempRoot()
        let backend = MockBackend("apple", [ok("code", 0.9)])
        let deps = try testDeps(root, backends: [backend], native: FakeNative(isScreenCapture: nil))
        let src = try Fixtures.drop("blank.png", into: deps.config.inbox, as: "photo.png")
        let result = await processJob(try await deps.database.createJob(path: src, originalName: "photo.png", context: nil).id, deps: deps)
        guard case .skipped(let reason) = result else { Issue.record("expected skipped, got \(result)"); return }
        #expect(reason == "not a screen capture (metadata source: none)")
        #expect(exists(src))
        #expect(backend.calls.isEmpty)

        // The same bytes under another name are skipped for the same reason, without a look.
        let copy = try Fixtures.drop("blank.png", into: deps.config.inbox, as: "photo copy.png")
        let again = await processJob(try await deps.database.createJob(path: copy, originalName: "photo copy.png", context: nil).id, deps: deps)
        #expect(again == .skipped(reason: reason))
    }

    @Test func requireScreenCaptureOffFilesAnyImage() async throws {
        let root = try tempRoot()
        let deps = try testDeps(
            root, backends: [MockBackend("apple", [ok("design", 0.9)])], native: FakeNative(isScreenCapture: nil),
            ["requireScreenCapture": false]
        )
        let src = try Fixtures.drop("blank.png", into: deps.config.inbox, as: "photo.png")
        _ = try filedShot(await processJob(try await deps.database.createJob(path: src, originalName: "photo.png", context: nil).id, deps: deps))
    }

    @Test func everyBackendFailingLeavesTheFile() async throws {
        let root = try tempRoot()
        let deps = try testDeps(
            root, backends: [MockBackend("apple", [fail(.error, "nope")]), MockBackend("codex", [fail(.timeout)], cloud: true)],
            native: FakeNative()
        )
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let job = try await deps.database.createJob(path: src, originalName: name, context: nil)
        let result = await processJob(job.id, deps: deps)
        guard case .failed(let error, let retry) = result else { Issue.record("expected failed, got \(result)"); return }
        #expect(retry)
        #expect(error.contains("all backends failed"))
        #expect(exists(src))
        let row = try #require(try await deps.database.job(id: job.id))
        #expect(row.status == .failed)
        #expect(row.attempts == 1)
        #expect(row.lastError?.contains("all backends failed") == true)
        #expect(!exists(deps.config.outputRoot))
    }

    @Test func copiesBeforeClassifyingAndOnlyOnTheFirstAttempt() async throws {
        let root = try tempRoot()
        let native = FakeNative()
        let deps = try testDeps(root, backends: [MockBackend("apple", [fail(.error, "down")])], native: native)
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let job = try await deps.database.createJob(path: src, originalName: name, context: appContext())
        _ = await processJob(job.id, deps: deps)
        #expect(native.clipboard == [src]) // there even though classification failed
        try await deps.database.requeueJob(job.id)
        _ = await processJob(job.id, deps: deps)
        #expect(native.clipboard == [src]) // the retry didn't copy again
    }

    @Test func ocrFailureLeavesTheFile() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9)])], native: FakeNative(ocrFails: true))
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let result = await processJob(try await deps.database.createJob(path: src, originalName: name, context: nil).id, deps: deps)
        #expect(result == .failed(error: "ocr exploded", retry: true))
        #expect(exists(src))
    }

    @Test func retryStopsAfterMaxAttempts() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [fail(.error)])], native: FakeNative(), ["maxAttempts": 2])
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let job = try await deps.database.createJob(path: src, originalName: name, context: nil)
        guard case .failed(_, true) = await processJob(job.id, deps: deps) else { Issue.record("first attempt should retry"); return }
        try await deps.database.requeueJob(job.id)
        guard case .failed(_, false) = await processJob(job.id, deps: deps) else { Issue.record("second attempt should not retry"); return }
    }

    @Test func denylistedAppNeverReachesTheCloud() async throws {
        let root = try tempRoot()
        let cloud = MockBackend("claude-code", [ok("finance", 0.99)], cloud: true)
        let deps = try testDeps(root, backends: [MockBackend("apple", [fail(.unavailable, "modelNotReady")]), cloud], native: FakeNative())
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let context = appContext(bundleId: "com.1password.1password", appName: "1Password")
        let shot = try filedShot(await processJob(try await deps.database.createJob(path: src, originalName: name, context: context).id, deps: deps))
        #expect(cloud.calls.isEmpty)
        #expect(shot.backend == "rules")
        let attempts = try JSONValue.parse(try #require(shot.attemptsJSON)).arrayValue ?? []
        #expect(attempts.map { $0["backend"]?.stringValue } == ["apple", "claude-code", "rules"])
        #expect(attempts[1]["outcome"]?["kind"]?.stringValue == "skipped")
    }

    @Test func nameCollisionsGetANumericSuffix() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9, title: "Same title")])], native: FakeNative())
        var names: [String] = []
        for fixture in ["code.png", "error.png"] {
            let src = try Fixtures.drop(fixture, into: deps.config.inbox, as: fixture)
            let shot = try filedShot(await processJob(try await deps.database.createJob(path: src, originalName: fixture, context: nil).id, deps: deps))
            names.append(Paths.basename(shot.path))
        }
        // Both were captured within the same minute (fixture copies), so the second gets -2.
        #expect(names[1] == names[0].replacing(".png", with: "-2.png"))
    }

    @Test func aFailedMoveDeletesTheRow() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9)])], native: FakeNative())
        // A file where the category folder should be makes the move fail.
        try FileManager.default.createDirectory(atPath: deps.config.outputRoot, withIntermediateDirectories: true)
        try Data().write(to: URL(filePath: Paths.join(deps.config.outputRoot, "code")))
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let result = await processJob(try await deps.database.createJob(path: src, originalName: name, context: nil).id, deps: deps)
        guard case .failed = result else { Issue.record("expected failed, got \(result)"); return }
        #expect(exists(src))
        #expect(try await deps.database.stats().shots == 0)
    }
}

@Suite struct RecatTests {
    @Test func manualCategorySwapsTheTagsItApplied() async throws {
        let root = try tempRoot()
        let native = FakeNative()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9, title: "Thing", tags: ["alpha"])])], native: native)
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let original = try filedShot(await processJob(try await deps.database.createJob(path: src, originalName: name, context: nil).id, deps: deps))
        try await native.setTags(original.path, ["user-own-tag"])

        let output = try await recat(original, options: RecatOptions(category: "design"), deps: deps)
        let shot = output.shot
        #expect(shot.path.hasPrefix(Paths.join(deps.config.outputRoot, "design") + "/"))
        #expect(!exists(original.path))
        #expect(exists(shot.path))
        #expect(shot.category == "design")
        #expect(shot.backend == "manual")
        #expect(shot.review == false)
        #expect(shot.title == "Thing")
        #expect(output.decision.attempts.isEmpty)
        #expect(native.tags[shot.path]?.sorted() == ["alpha", "design"])
        #expect(native.clipboard.isEmpty) // no live context, and recat never copies
    }

    @Test func unknownCategoryIsAnError() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9)])], native: FakeNative())
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let shot = try filedShot(await processJob(try await deps.database.createJob(path: src, originalName: name, context: nil).id, deps: deps))
        await #expect(throws: ShotsError("unknown category \"nope\" (have: \(deps.config.categories.joined(separator: ", ")))")) {
            try await recat(shot, options: RecatOptions(category: "nope"), deps: deps)
        }
    }

    @Test func reclassifiesWithAnExplicitBackend() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("misc", 0.3)])], native: FakeNative())
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let original = try filedShot(await processJob(try await deps.database.createJob(path: src, originalName: name, context: appContext()).id, deps: deps))
        #expect(original.review)
        #expect(try await deps.database.reviewQueue().count == 1)

        let codex = MockBackend("codex", [ok("errors", 0.9, title: "Python traceback")], cloud: true)
        let output = try await recat(original, options: RecatOptions(backends: [codex]), deps: deps)
        let shot = output.shot
        #expect(codex.calls.first?.ocrText == original.ocrText)
        #expect(codex.calls.first?.dimensions == .init(width: 800, height: 600))
        #expect(codex.calls.first?.appContext?.bundleId == "com.microsoft.VSCode")
        #expect(shot.category == "errors")
        #expect(shot.backend == "codex")
        #expect(shot.review == false)
        #expect(shot.title == "Python traceback")
        #expect(try await deps.database.reviewQueue().isEmpty)
        #expect(try await deps.database.search("traceback").map(\.shot.id) == [shot.id])

        let json = output.json
        #expect(json["shot"]?["category"]?.stringValue == "errors")
        #expect(json["decision"]?["backend"]?.stringValue == "codex")
    }

    @Test func refusesAnExplicitCloudBackendForADenylistedShot() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("finance", 0.9)])], native: FakeNative())
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let context = appContext(bundleId: "com.1password.1password", appName: "1Password")
        let shot = try filedShot(await processJob(try await deps.database.createJob(path: src, originalName: name, context: context).id, deps: deps))
        let codex = MockBackend("codex", [ok("code", 0.9)], cloud: true)
        do {
            _ = try await recat(shot, options: RecatOptions(backends: [codex]), deps: deps)
            Issue.record("recat should refuse")
        } catch {
            #expect(errorMessage(error).hasPrefix("refusing to send to codex: denylisted app"))
        }
        #expect(codex.calls.isEmpty)
    }

    @Test func goneFileIsAnError() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9)])], native: FakeNative())
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let shot = try filedShot(await processJob(try await deps.database.createJob(path: src, originalName: name, context: nil).id, deps: deps))
        try FileManager.default.removeItem(atPath: shot.path)
        await #expect(throws: ShotsError("file is gone: \(shot.path)")) {
            try await recat(shot, options: RecatOptions(category: "design"), deps: deps)
        }
    }
}

@Suite struct FinderTagTests {
    @Test func categoryTagsAndReviewWithoutDuplicates() {
        let decision = ChainDecision(
            final: ClassifyResult(category: "misc", tags: ["misc", "a", "a"], title: "t", confidence: 0.2),
            backend: "apple", review: true, suggestedCategory: "x", attempts: []
        )
        #expect(finderTags(decision) == ["misc", "a", "review"])
    }
}
