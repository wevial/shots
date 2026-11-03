import Foundation
import Testing
@testable import ShotsCore

private let name = "Screenshot 2026-10-21 at 10.22.28 AM.png"

struct ScratchHintTests {
    private let apps = Config.defaultScratchApps

    @Test func codingToolsAreAHint() {
        let claude = appContext(bundleId: "com.anthropic.claudefordesktop", appName: "Claude", windowTitle: "Claude")
        #expect(scratchHints(claude, scratchApps: apps) == ["captured in Claude, a coding or development tool"])
        // By app name too, case-insensitively.
        let named = appContext(bundleId: "sh.example.holophyte", appName: "Holophyte")
        #expect(scratchHints(named, scratchApps: ["holophyte"]).count == 1)
        #expect(scratchHints(appContext(bundleId: "com.apple.Safari", appName: "Safari"), scratchApps: apps).isEmpty)
        #expect(scratchHints(nil, scratchApps: apps).isEmpty)
    }

    @Test(arguments: [
        "http://localhost:3000/settings", "http://127.0.0.1/", "https://relos-dev.vercel.app/transaction/1",
        "https://relos-pk8tkurp9-relos.vercel.app/", "https://staging.example.com/", "http://192.168.1.20/admin",
        "https://example.com:8443/", "http://myapp.test/", "https://preview-42.example.dev/",
    ])
    func devHosts(_ url: String) {
        let ctx = appContext(bundleId: "company.thebrowser.dia", appName: "Dia", url: url)
        #expect(scratchHints(ctx, scratchApps: apps).first?.hasPrefix("the browser tab is a local, development or preview build") == true)
    }

    @Test(arguments: ["https://github.com/wevial/shots/pull/1", "https://www.relos.com/transaction/1", "https://developer.apple.com/"])
    func productionHosts(_ url: String) {
        let ctx = appContext(bundleId: "company.thebrowser.dia", appName: "Dia", url: url)
        #expect(scratchHints(ctx, scratchApps: apps).isEmpty)
    }

    @Test func hintsReachThePrompt() {
        let input = ClassifyInput(
            imagePath: "/x.png", ocrText: "Save", appContext: nil, captureType: nil, dimensions: nil, categories: ["misc"],
            scratchHints: ["captured in Claude, a coding or development tool"]
        )
        #expect(Prompt.build(input, maxOcrChars: 100).contains("- hint: captured in Claude, a coding or development tool\n"))
        #expect(Prompt.instructions.contains("Scratch: true for a throwaway"))
    }

    @Test func rulesCallItScratchOnlyWithAHint() async {
        let rules = RulesBackend(appRules: [:])
        var input = ClassifyInput(imagePath: "/x.png", ocrText: "", appContext: nil, captureType: nil, dimensions: nil, categories: ["misc"])
        #expect(await rules.classify(input).result?.scratch == false)
        input.scratchHints = ["the browser tab is a local, development or preview build (localhost)"]
        #expect(await rules.classify(input).result?.scratch == true)
    }
}

struct ScratchValidationTests {
    private let base: JSONObject = ["category": "code", "tags": [], "title": "T", "confidence": 0.8]

    @Test func readsScratch() {
        var raw = base
        raw["scratch"] = true
        #expect(validateResult(.object(raw)) == .valid(ClassifyResult(category: "code", tags: [], title: "T", confidence: 0.8, scratch: true)))
    }

    @Test func missingScratchIsFalse() {
        #expect(validateResult(.object(base)) == .valid(ClassifyResult(category: "code", tags: [], title: "T", confidence: 0.8)))
    }

    @Test func nonBooleanScratchIsInvalid() {
        var raw = base
        raw["scratch"] = "yes"
        #expect(validateResult(.object(raw)) == .invalid(["scratch must be true or false"]))
    }
}

struct CleanupIndexTests {
    private func shot(_ n: Int, capturedAt: String, scratch: Bool?) -> NewShot {
        NewShot(
            path: "/out/code/shot-\(n).png", originalName: "Screenshot \(n).png", sha256: "sha-\(n)",
            capturedAt: capturedAt, processedAt: Timestamp.now(), category: "code", title: "Shot \(n)",
            confidence: 0.9, backend: "apple", scratch: scratch
        )
    }

    @Test func suggestsOldScratchShotsUntilKept() async throws {
        let db = try Database(path: ":memory:")
        let old = try await db.insertShot(shot(1, capturedAt: "2026-10-01T10:00:00.000Z", scratch: true))
        _ = try await db.insertShot(shot(2, capturedAt: "2026-10-02T10:00:00.000Z", scratch: false))
        _ = try await db.insertShot(shot(3, capturedAt: "2026-10-30T10:00:00.000Z", scratch: true)) // too recent
        let unjudged = try await db.insertShot(shot(4, capturedAt: "2026-10-03T10:00:00.000Z", scratch: nil))
        let cutoff = try #require(Timestamp.parse("2026-10-29T00:00:00.000Z"))

        #expect(try await db.cleanupSuggestions(capturedBefore: cutoff).map(\.id) == [old.id])
        #expect(try await db.unjudgedShots().map(\.id) == [unjudged.id])

        try await db.setScratch(unjudged.id, true)
        #expect(try await db.cleanupSuggestions(capturedBefore: cutoff).map(\.id) == [unjudged.id, old.id])
        try await db.keep(old.id)
        #expect(try await db.cleanupSuggestions(capturedBefore: cutoff).map(\.id) == [unjudged.id])
        #expect(try await db.shot(id: old.id)?.kept == true)
    }

    @Test func removingAShotUnlinksItsJob() async throws {
        let db = try Database(path: ":memory:")
        let row = try await db.insertShot(shot(1, capturedAt: Timestamp.now(), scratch: true))
        let job = try await db.createJob(path: "/inbox/a.png", originalName: "a.png", context: nil)
        try await db.finishJob(job.id, status: .done, sha256: row.sha256, shotId: row.id)

        try await db.removeShot(row.id)
        #expect(try await db.shot(id: row.id) == nil)
        #expect(try await db.job(id: job.id)?.shotId == nil)
        #expect(try await db.search("Shot").isEmpty)
    }

    @Test func addsTheColumnsToAnOlderIndex() async throws {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../ShotsKitTests/Fixtures/fixture.db").standardized
        let copy = Paths.join(try tempRoot(), "shots.db")
        try FileManager.default.copyItem(atPath: fixture.path, toPath: copy)
        let db = try Database(path: copy)
        let unjudged = try await db.unjudgedShots()
        #expect(unjudged.count == 6)
        #expect(unjudged.allSatisfy { $0.scratch == nil && !$0.kept })
        await db.close()
        _ = try Database(path: copy) // a second open finds the columns and adds nothing
    }
}

struct CleanupPipelineTests {
    @Test func filingStoresTheVerdictAndManualRecatKeepsIt() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9, scratch: true)])], native: FakeNative())
        let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: name)
        let job = try await deps.database.createJob(path: src, originalName: name, context: appContext())
        guard case .done(let filed) = await processJob(job.id, deps: deps) else { Issue.record("not filed"); return }
        #expect(filed.scratch == true)

        let moved = try await recat(filed, options: RecatOptions(category: "docs"), deps: deps)
        #expect(moved.shot.scratch == true)
    }

    @Test func judgingAnOlderShotOnlyStoresTheVerdict() async throws {
        let root = try tempRoot()
        let backend = MockBackend("apple", [ok("errors", 0.9, title: "Something else", scratch: true)])
        let deps = try testDeps(root, backends: [backend], native: FakeNative())
        let path = try Fixtures.drop("code.png", into: Paths.join(deps.config.outputRoot, "code"), as: "kept.png")
        let row = try await deps.database.insertShot(NewShot(
            path: path, originalName: name, sha256: "sha", capturedAt: Timestamp.now(), processedAt: Timestamp.now(),
            appBundleId: "com.anthropic.claudefordesktop", appName: "Claude", ocrText: "Save", category: "code",
            title: "Original", confidence: 0.9, backend: "apple"
        ))

        #expect(try await judgeScratch(row, deps: deps) == true)
        let after = try #require(try await deps.database.shot(id: row.id))
        #expect(after.scratch == true)
        #expect(after.path == path && after.category == "code" && after.title == "Original")
        #expect(backend.calls.first?.scratchHints == ["captured in Claude, a coding or development tool"])
    }

    @Test func trashingMovesTheFileAndDropsTheRow() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [], native: FakeNative())
        let path = try Fixtures.drop("code.png", into: Paths.join(root, "out"), as: "a.png")
        let row = try await deps.database.insertShot(NewShot(
            path: path, originalName: name, sha256: "sha", capturedAt: Timestamp.now(), processedAt: Timestamp.now(),
            category: "code", title: "A", confidence: 0.9, backend: "apple", scratch: true
        ))
        let trash = Paths.join(root, "Trash")
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)

        try await trashShot(row, database: deps.database) { try FileManager.default.moveItem(atPath: $0, toPath: Paths.join(trash, "a.png")) }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: Paths.join(trash, "a.png")))
        #expect(try await deps.database.shot(id: row.id) == nil)

        // A file that's already gone just leaves the index.
        let gone = try await deps.database.insertShot(NewShot(
            path: Paths.join(root, "missing.png"), originalName: name, sha256: "sha2", capturedAt: Timestamp.now(),
            processedAt: Timestamp.now(), category: "code", title: "B", confidence: 0.9, backend: "apple"
        ))
        try await trashShot(gone, database: deps.database) { _ in Issue.record("nothing to trash") }
        #expect(try await deps.database.shot(id: gone.id) == nil)
    }
}
