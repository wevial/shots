import Foundation
import Testing
@testable import ShotsCore

/// The Swift daemon has to take over an index the TypeScript daemon built. fixture.db
/// (ShotsKitTests/Fixtures, made by src/db.ts's own Store) stands in for that index.
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
}
