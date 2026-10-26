import Foundation
import Testing
@testable import ShotsKit

/// Runs the store against `Fixtures/fixture.db`, which the TypeScript daemon's own `Store`
/// wrote before the Swift port, so a change that can't read a TS-era index shows up here.
struct FixtureStoreTests {
    let store: ShotStore

    init() throws {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fixture.db")
        // Copy so a read-only open never touches the committed file (no -shm/-wal droppings).
        let copy = URL.temporaryDirectory.appending(path: "fixture-\(UUID().uuidString).db")
        try FileManager.default.copyItem(at: fixture, to: copy)
        store = try ShotStore(path: copy.path)
    }

    @Test func listsNewestFirst() async throws {
        #expect(try await store.shots(in: .all).map(\.id) == [4, 3, 2, 1, 5, 6])
    }

    @Test func categoryAndReviewScopes() async throws {
        #expect(try await store.shots(in: .category("errors")).map(\.id) == [1, 6])
        let review = try await store.shots(in: .review)
        #expect(review.map(\.id) == [4])
        #expect(review.first?.suggestedCategory == "receipts")
        #expect(review.first?.needsReview == true)
    }

    @Test func counts() async throws {
        let counts = try await store.counts()
        #expect(counts.all == 6)
        #expect(counts.review == 1)
        #expect(counts.failed == 1)
        #expect(counts.byCategory["errors"] == 2)
        #expect(counts.deleted == 0) // From before Recently Deleted: nothing in it.
        #expect(try await store.shots(in: .deleted).isEmpty)
        #expect(counts.count(for: .category("design")) == 1)
    }

    @Test func failedJobs() async throws {
        let jobs = try await store.failedJobs()
        #expect(jobs.count == 1)
        #expect(jobs.first?.fileName == "broken.png")
        #expect(jobs.first?.lastError == "every backend failed")
        #expect(jobs.first?.attempts == 1)
    }

    @Test func tagsAndOptionalColumns() async throws {
        let shot = try #require(try await store.shot(id: 2))
        #expect(shot.tags == ["dashboard", "charts"])
        #expect(shot.pageURL == URL(string: "https://example.com/dashboard"))
        #expect(shot.pageTitle == "Example Dashboard")
        #expect(shot.classifierBackend == .claudeCode)
        #expect(shot.pixelSize == "1440 × 900")
        let plain = try #require(try await store.shot(id: 5))
        #expect(plain.pageURL == nil)
        #expect(plain.classifierBackend == .manual)
        #expect(try await store.shot(id: 999) == nil)
    }

    @Test func recentShots() async throws {
        #expect(try await store.recentShots(limit: 2).map(\.id) == [4, 3])
    }

    @Test func searchPrefixMatch() async throws {
        #expect(try await store.shots(in: .all, matching: "compil").map(\.id) == [1])
    }

    @Test func searchMultipleTermsMustAllMatch() async throws {
        #expect(try await store.shots(in: .all, matching: "queued workers").map(\.id) == [2])
        #expect(try await store.shots(in: .all, matching: "queued espresso").isEmpty)
    }

    @Test func searchMatchesURLAndAppColumns() async throws {
        #expect(try await store.shots(in: .all, matching: "xcode").map(\.id) == [1])
        #expect(try await store.shots(in: .all, matching: "example.com").map(\.id) == [2])
    }

    @Test func searchWithinScope() async throws {
        #expect(try await store.shots(in: .category("errors"), matching: "timeout").map(\.id) == [6])
        #expect(try await store.shots(in: .category("design"), matching: "timeout").isEmpty)
        #expect(try await store.shots(in: .review, matching: "invoice").map(\.id) == [4])
    }

    @Test func searchNoMatch() async throws {
        #expect(try await store.shots(in: .all, matching: "zzzxyz").isEmpty)
    }

    @Test(arguments: ["!?-*", "   ", "\"\""])
    func punctuationOnlyQueryIsNotASearch(_ query: String) async throws {
        // No searchable words means "no search": the plain listing, never an FTS syntax error.
        #expect(try await store.shots(in: .all, matching: query).count == 6)
    }

    @Test func ftsSyntaxInInputIsHarmless() async throws {
        _ = try await store.shots(in: .all, matching: #"foo AND (bar" NEAR"#)
    }

    @Test func dataVersionIsReadable() async throws {
        _ = try await store.dataVersion()
    }
}
