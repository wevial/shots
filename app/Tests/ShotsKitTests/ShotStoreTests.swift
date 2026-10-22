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
        #expect(counts == ScopeCounts(all: 3, review: 1, failed: 1, byCategory: ["code": 1, "receipts": 1, "misc": 1]))
        let jobs = try await store.failedJobs()
        #expect(jobs.map(\.fileName) == ["job-1.png"])
        #expect(jobs.first?.attempts == 3)
    }

    @Test func dataVersionChangesWhenAnotherConnectionWrites() async throws {
        let before = try await store.dataVersion()
        #expect(try await store.dataVersion() == before)
        try db.insertShot(id: 4, category: "code", title: "New", capturedAt: "2026-10-22T10:00:00.000Z")
        #expect(try await store.dataVersion() != before)
    }

    @Test func missingDatabaseThrows() {
        #expect(throws: SQLiteError.self) { try ShotStore(path: "/nonexistent/shots.db") }
    }
}
