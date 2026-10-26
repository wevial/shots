import Foundation
import Testing
@testable import ShotsCore

struct DatabaseTests {
    private func newShot(_ n: Int, title: String = "Load config function", ocr: String = "export function loadConfig", tags: [String] = ["typescript", "config"], review: Bool = false) -> NewShot {
        NewShot(
            path: "/out/code/shot-\(n).png", originalName: "Screenshot \(n).png", sha256: "sha-\(n)",
            capturedAt: "2026-10-21T10:0\(n):00.000Z", processedAt: Timestamp.now(),
            appBundleId: "com.microsoft.VSCode", appName: "Code", windowTitle: "config.ts — shots",
            captureType: "selection", width: 800, height: 600, ocrText: ocr, category: "code",
            tags: tags, title: title, confidence: 0.9, backend: "apple", review: review, attemptsJSON: "[]"
        )
    }

    @Test func jobStateMachine() async throws {
        let db = try Database(path: ":memory:")
        let ctx = appContext()
        let job = try await db.createJob(path: "/in/a.png", originalName: "a.png", context: ctx)
        #expect(job.status == .pending)
        #expect(job.attempts == 0)
        #expect(job.context == ctx)
        #expect(try await db.activeJob(forPath: "/in/a.png")?.id == job.id)
        #expect(try await db.pendingJobs().map(\.id) == [job.id])

        let started = try await db.startJob(job.id)
        #expect(started.status == .processing)
        #expect(started.attempts == 1)

        #expect(try await db.resetInterrupted() == 1)
        #expect(try await db.job(id: job.id)?.status == .pending)

        _ = try await db.startJob(job.id)
        try await db.finishJob(job.id, status: .failed, error: "boom")
        #expect(try await db.activeJob(forPath: "/in/a.png") == nil)
        #expect(try await db.failedJobs().map(\.lastError) == ["boom"])

        try await db.requeueJob(job.id)
        let requeued = try #require(try await db.job(id: job.id))
        #expect(requeued.status == .pending)
        #expect(requeued.attempts == 2) // the interrupted run counted too
        #expect(requeued.context == ctx) // kept

        try await db.requeueJob(job.id, context: nil)
        #expect(try await db.job(id: job.id)?.contextJSON == nil)

        _ = try await db.startJob(job.id)
        try await db.finishJob(job.id, status: .skipped, error: "not a screen capture", sha256: "abc")
        let skipped = try #require(try await db.job(id: job.id))
        #expect(skipped.sha256 == "abc")
        #expect(skipped.attempts == 3)
        let other = try await db.createJob(path: "/in/b.png", originalName: "b.png", context: nil)
        #expect(try await db.skippedJob(forSha: "abc", except: other.id)?.id == job.id)
        #expect(try await db.skippedJob(forSha: "abc", except: job.id) == nil)
        #expect(try await db.latestJob(forPath: "/in/a.png")?.id == job.id)
    }

    @Test func onlyOneActiveJobPerPath() async throws {
        let db = try Database(path: ":memory:")
        _ = try await db.createJob(path: "/in/a.png", originalName: "a.png", context: nil)
        await #expect(throws: SQLiteError.self) {
            _ = try await db.createJob(path: "/in/a.png", originalName: "a.png", context: nil)
        }
    }

    @Test func contextJSONMatchesTheTypeScriptShape() async throws {
        let db = try Database(path: ":memory:")
        let ctx = AppContext(bundleId: "com.apple.Safari", appName: "Safari", capturedAt: "2026-10-21T10:00:00.000Z")
        let job = try await db.createJob(path: "/in/a.png", originalName: "a.png", context: ctx)
        #expect(job.contextJSON == #"{"bundleId":"com.apple.Safari","appName":"Safari","windowTitle":null,"url":null,"urlTitle":null,"capturedAt":"2026-10-21T10:00:00.000Z","accessibility":false,"notes":[]}"#)
    }

    @Test func insertSearchUpdateAndFind() async throws {
        let db = try Database(path: ":memory:")
        let shot = try await db.insertShot(newShot(1))
        #expect(shot.tagsText == "typescript config")
        #expect(shot.tags == ["typescript", "config"])
        #expect(shot.tagsJSON == #"["typescript","config"]"#)
        #expect(try await db.shot(bySha: "sha-1") == shot)

        #expect(try await db.search("loadconfig").map(\.shot.id) == [shot.id])
        #expect(try await db.search("typescript").count == 1)
        #expect(try await db.search("shots").count == 1) // window title
        #expect(try await db.search("   ").isEmpty)
        #expect(try await db.search("loadCon").first?.snippet.contains("[loadConfig]") == true)

        let updated = try await db.updateShot(shot.id, ShotUpdate(
            path: "/out/errors/x.png", category: "errors", suggestedCategory: nil, tags: ["python"],
            title: "Python traceback", confidence: 0.9, backend: "codex", review: false, attemptsJSON: "[]"
        ))
        #expect(updated.category == "errors")
        #expect(updated.tagsText == "python")
        #expect(try await db.search("traceback").map(\.shot.id) == [shot.id])
        #expect(try await db.search("typescript").isEmpty) // FTS follows the update trigger

        #expect(try await db.findShot("/out/errors/x.png", resolvedPath: "/out/errors/x.png")?.id == shot.id)
        #expect(try await db.findShot("Screenshot 1.png", resolvedPath: "/cwd/Screenshot 1.png")?.id == shot.id)
        #expect(try await db.findShot("x.png", resolvedPath: "/cwd/x.png")?.id == shot.id)
        #expect(try await db.findShot("nope.png", resolvedPath: "/cwd/nope.png") == nil)

        try await db.deleteShot(shot.id)
        #expect(try await db.search("traceback").isEmpty)
    }

    /// A duplicated shot has its original's bytes. The inbox's dedupe lookup still finds one.
    @Test func sameShaIsAllowedForCopies() async throws {
        let db = try Database(path: ":memory:")
        let original = try await db.insertShot(newShot(1))
        var copy = newShot(2)
        copy.sha256 = "sha-1"
        _ = try await db.insertShot(copy)
        #expect(try await db.shot(bySha: "sha-1")?.sha256 == original.sha256)
    }

    @Test func reviewQueueAndStats() async throws {
        let db = try Database(path: ":memory:")
        _ = try await db.insertShot(newShot(1))
        let flagged = try await db.insertShot(newShot(2, review: true))
        let job = try await db.createJob(path: "/in/a.png", originalName: "a.png", context: nil)
        _ = try await db.startJob(job.id)
        try await db.finishJob(job.id, status: .done, sha256: "sha-1", shotId: flagged.id)
        #expect(try await db.reviewQueue().map(\.id) == [flagged.id])
        let stats = try await db.stats()
        #expect(stats.shots == 2)
        #expect(stats.review == 1)
        #expect(stats.jobs == ["done": 1])
        #expect(stats.byBackend == [.init(backend: "apple", count: 2)])
    }

    @Test func reopensAnExistingIndexOnDisk() async throws {
        let root = try tempRoot()
        let path = Paths.join(root, "data/shots.db")
        let first = try Database(path: path)
        let shot = try await first.insertShot(newShot(1))
        await first.close()
        let second = try Database(path: path) // schema is create-if-not-exists
        #expect(try await second.shot(id: shot.id) == shot)
    }

    @Test func shotJSONIsTheRawRowInColumnOrder() async throws {
        let db = try Database(path: ":memory:")
        let shot = try await db.insertShot(newShot(1))
        let keys = shot.json.objectValue?.keys
        #expect(keys == [
            "id", "path", "original_name", "sha256", "captured_at", "processed_at", "app_bundle_id", "app_name",
            "window_title", "url", "url_title", "capture_type", "width", "height", "ocr_text", "category",
            "suggested_category", "tags_json", "tags_text", "title", "confidence", "backend", "review", "attempts_json",
            "scratch", "kept",
        ])
        #expect(shot.json["url"] == .null)
        #expect(shot.json["review"] == 0)
    }

    @Test func ftsQueryQuotesEveryWord() {
        #expect(toFtsQuery("load config") == #""load"* "config"*"#)
        #expect(toFtsQuery(#"a" OR "b"#) == #""a"* "OR"* "b"*"#)
        #expect(toFtsQuery("—") == "")
    }
}
