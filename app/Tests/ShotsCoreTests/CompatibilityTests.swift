import Foundation
import Testing
@testable import ShotsCore

/// The Swift daemon has to take over an index the TypeScript daemon built. fixture.db
/// (ShotsKitTests/Fixtures, made by the TypeScript daemon's Store) stands in for that index.
struct CompatibilityTests {
    private func openFixture() throws -> Database {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../ShotsKitTests/Fixtures/fixture.db").standardized
        let copy = Paths.join(try tempRoot(), "shots.db")
        try FileManager.default.copyItem(atPath: fixture.path, toPath: copy)
        return try Database(path: copy)
    }

    @Test func opensAndReadsAnIndexTheTypeScriptDaemonWrote() async throws {
        let db = try openFixture()
        let stats = try await db.stats()
        #expect(stats.shots == 6)
        #expect(stats.review == 1)
        #expect(stats.jobs["failed"] == 1)
        #expect(try await db.reviewQueue().first?.suggestedCategory == "receipts")
        #expect(try await db.failedJobs().count == 1)
    }

    @Test func writesIntoItWithTheTriggersStillWorking() async throws {
        let db = try openFixture()
        let shot = try await db.insertShot(NewShot(
            path: "/fixture/Screenshots/code/new.png", originalName: "Screenshot new.png", sha256: "sha-new",
            capturedAt: Timestamp.now(), processedAt: Timestamp.now(), ocrText: "zanzibar quokka",
            category: "code", tags: ["quokka"], title: "Quokka", confidence: 0.9, backend: "apple"
        ))
        #expect(try await db.search("zanzibar").map(\.shot.id) == [shot.id])
        #expect(try await db.stats().shots == 7)
    }

    @Test func dropsTheUniqueHashSoDuplicatesFit() async throws {
        let db = try openFixture()
        let original = try #require(try await db.reviewQueue().first)
        let ddl = try SQLiteConnection(path: db.path).query("select sql from sqlite_master where name = 'shots'") { $0.string("sql") ?? "" }
        #expect(ddl.first?.contains("sha256 text not null unique") == false)

        var copy = NewShot(
            path: original.path + "-copy.png", originalName: original.originalName, sha256: original.sha256,
            capturedAt: original.capturedAt, processedAt: Timestamp.now(), ocrText: "walrus",
            category: original.category, title: "Copy", confidence: 1, backend: "manual")
        let inserted = try await db.insertShot(copy)
        #expect(try await db.stats().shots == 7)
        #expect(try await db.search("walrus").map(\.shot.id) == [inserted.id])
        // Rows, ids and the search index came through the rebuild.
        #expect(try await db.shot(id: original.id) == original)
        #expect(try await db.search(original.title).contains { $0.shot.id == original.id })

        // A second open finds nothing left to migrate; paths are still unique.
        _ = try Database(path: db.path)
        copy.sha256 = "other"
        await #expect(throws: SQLiteError.self) { try await db.insertShot(copy) }
    }

    @Test func addsRecentlyDeletedsColumns() async throws {
        let db = try openFixture()
        let columns = try SQLiteConnection(path: db.path).query("pragma table_info(shots)") { $0.string("name") ?? "" }
        #expect(columns.suffix(2) == ["deleted_at", "deleted_from"])
        let shot = try #require(try await db.reviewQueue().first)
        _ = try await db.markDeleted(shot.id, path: "/elsewhere.png", from: shot.path)
        #expect(try await db.reviewQueue().isEmpty)
        #expect(try await db.stats().shots == 5)
        _ = try Database(path: db.path) // Nothing left to migrate.
    }

    @Test func removingAFiledShotUnlinksItsJob() async throws {
        let db = try openFixture()
        let jobs = try SQLiteConnection(path: db.path).query("select shot_id from jobs where shot_id is not null") { $0.int("shot_id") ?? 0 }
        let id = try #require(jobs.first)
        try await db.removeShot(id)
        #expect(try await db.shot(id: id) == nil)
        #expect(try await db.stats().shots == 5)
    }
}
