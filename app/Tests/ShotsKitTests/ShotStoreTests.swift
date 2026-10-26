import Foundation
import Testing
@testable import ShotsKit

struct ShotStoreTests {
    let db: TestDatabase
    let store: ShotStore

    init() throws {
        db = try TestDatabase()
        try db.insertShot(id: 1, category: "code", title: "Swift build error", ocr: "error: cannot find type", capturedAt: "2026-10-20T10:00:00.000Z")
        try db.insertShot(id: 2, category: "receipts", title: "Coffee receipt", ocr: "Total 4.50", capturedAt: "2026-10-21T10:00:00.000Z")
        try db.insertShot(id: 3, category: "misc", title: "Unclear", ocr: "maybe a receipt", capturedAt: "2026-10-19T10:00:00.000Z", review: true)
        try db.insertShot(id: 4, category: "code", title: "Deleted error", ocr: "error: gone", capturedAt: "2026-10-22T10:00:00.000Z",
                          review: true, deletedAt: "2026-10-23T10:00:00.000Z")
        try db.insertShot(id: 5, category: "code", title: "Deleted earlier", capturedAt: "2026-10-22T11:00:00.000Z",
                          deletedAt: "2026-10-22T12:00:00.000Z")
        try db.insertFailedJob(id: 1)
        store = try ShotStore(path: db.path)
    }

    @Test func allIsNewestFirst() async throws {
        #expect(try await store.shots(in: .all).map(\.id) == [2, 1, 3])
    }

    @Test func scopesFilter() async throws {
        #expect(try await store.shots(in: .review).map(\.id) == [3])
        #expect(try await store.shots(in: .category("code")).map(\.id) == [1])
        #expect(try await store.shots(in: .failed).isEmpty)
    }

    @Test func cleanupHoldsOldScratchShotsNobodyKept() async throws {
        try db.insertShot(id: 6, category: "code", title: "Layout glitch", capturedAt: "2026-10-18T10:00:00.000Z", scratch: true)
        try db.insertShot(id: 7, category: "code", title: "Kept glitch", capturedAt: "2026-10-17T10:00:00.000Z", scratch: true, kept: true)
        try db.insertShot(id: 8, category: "code", title: "Fresh glitch", capturedAt: "2026-10-22T10:00:00.000Z", scratch: true)
        try db.insertShot(id: 9, category: "code", title: "Worth keeping", capturedAt: "2026-10-16T10:00:00.000Z", scratch: false)
        try db.insertShot(id: 10, category: "code", title: "Deleted glitch", capturedAt: "2026-10-15T10:00:00.000Z", scratch: true,
                          deletedAt: "2026-10-23T10:00:00.000Z")
        let cutoff = try #require(ISODate.parse("2026-10-21T00:00:00.000Z"))

        #expect(try await store.shots(in: .cleanup, cleanupCutoff: cutoff).map(\.id) == [6])
        #expect(try await store.shots(in: .cleanup, matching: "glitch", cleanupCutoff: cutoff).map(\.id) == [6])
        let counts = try await store.counts(cleanupCutoff: cutoff)
        #expect(counts.cleanup == 1)
        #expect(counts.unjudged == 3) // the three in the library from init()
        #expect(try await store.shot(id: 6)?.isScratch == true)
        #expect(try await store.shot(id: 7)?.isScratch == false)
        #expect(try await store.shot(id: 10)?.isScratch == false)
    }

    @Test func recentlyDeletedIsItsOwnScope() async throws {
        #expect(try await store.shots(in: .deleted).map(\.id) == [4, 5]) // Most recently deleted first.
        #expect(try await store.shots(in: .deleted, matching: "error").map(\.id) == [4])
        #expect(try await store.shots(in: .all, matching: "error").map(\.id) == [1])
        #expect(try await store.recentShots().map(\.id) == [2, 1, 3])
        #expect(try await store.shot(id: 4)?.isDeleted == true)
    }

    @Test func searchMatchesPrefixesWithinScope() async throws {
        #expect(try await Set(store.shots(in: .all, matching: "recei").map(\.id)) == [2, 3])
        #expect(try await store.shots(in: .review, matching: "recei").map(\.id) == [3])
        // The title column weighs most, so the shot titled "receipt" ranks first.
        #expect(try await store.shots(in: .all, matching: "receipt").first?.id == 2)
    }

    @Test func mapsColumns() async throws {
        let shot = try #require(try await store.shot(id: 1))
        #expect(shot.title == "Swift build error")
        #expect(shot.tags == ["tag1"])
        #expect(shot.capturedAt == ISODate.parse("2026-10-20T10:00:00.000Z"))
        #expect(shot.width == nil)
    }

    @Test func countsAndFailedJobs() async throws {
        let counts = try await store.counts()
        #expect(counts == ScopeCounts(all: 3, review: 1, failed: 1, unjudged: 3, deleted: 2, byCategory: ["code": 1, "receipts": 1, "misc": 1]))
        let jobs = try await store.failedJobs()
        #expect(jobs.map(\.fileName) == ["job-1.png"])
        #expect(jobs.first?.attempts == 3)
    }

    @Test func dataVersionChangesWhenAnotherConnectionWrites() async throws {
        let before = try await store.dataVersion()
        #expect(try await store.dataVersion() == before)
        try db.insertShot(id: 6, category: "code", title: "New", capturedAt: "2026-10-22T10:00:00.000Z")
        #expect(try await store.dataVersion() != before)
    }

    @Test func missingDatabaseThrows() {
        #expect(throws: SQLiteError.self) { try ShotStore(path: "/nonexistent/shots.db") }
    }
}
