import Foundation
import Testing
@testable import ShotsKit

@MainActor
struct AppModelTests {
    @Test func loadsScopeAndCounts() async throws {
        let db = try TestDatabase()
        try db.insertShot(id: 1, category: "code", title: "One", capturedAt: "2026-10-20T10:00:00.000Z")
        try db.insertShot(id: 2, category: "legacy", title: "Two", capturedAt: "2026-10-21T10:00:00.000Z", review: true)
        let model = AppModel(config: .sample, store: try ShotStore(path: db.path))

        await model.reload()
        #expect(model.shots.map(\.id) == [2, 1])
        #expect(model.counts.review == 1)
        // A category only the index knows about still gets a sidebar row, after the configured ones.
        #expect(model.categories.last == "legacy")

        model.scope = .review
        await model.reload()
        #expect(model.shots.map(\.id) == [2])
    }

    @Test func searchAllShotsIgnoresTheScopeAndSearchField() async throws {
        let db = try TestDatabase()
        try db.insertShot(id: 1, category: "code", title: "Checkout error", capturedAt: "2026-10-20T10:00:00.000Z")
        try db.insertShot(id: 2, category: "receipts", title: "Checkout receipt", capturedAt: "2026-10-21T10:00:00.000Z")
        try db.insertShot(id: 3, category: "code", title: "Unrelated", capturedAt: "2026-10-22T10:00:00.000Z")
        let model = AppModel(config: .sample, store: try ShotStore(path: db.path))
        model.scope = .category("code")
        model.searchText = "unrelated"

        #expect(Set(await model.searchAllShots("checkout", limit: 6).map(\.id)) == [1, 2])
        #expect(await model.searchAllShots("checkout", limit: 1).count == 1)
        #expect(await model.searchAllShots("  ", limit: 6).isEmpty)
    }

    @Test func recatWithoutCLIReportsAnError() async {
        let model = AppModel.preview()
        await model.recategorize(.sample, to: "code")
        #expect(model.lastError != nil)
        #expect(model.recategorizing.isEmpty)
    }

    @Test func missingFileActionsReportInsteadOfFailingSilently() {
        let model = AppModel.preview()
        model.quickLook(Shot.missingFileSample)
        #expect(model.quickLookURL == nil)
        #expect(model.isShowingError)
        model.isShowingError = false
        #expect(model.lastError == nil)
    }
}
