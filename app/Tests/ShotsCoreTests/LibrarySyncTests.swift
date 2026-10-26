import Foundation
import Synchronization
import Testing
@testable import ShotsCore

/// Files `code.png` as a code shot and returns it with deps whose OCR reads `ocrAfter`, as if
/// the file had since been edited.
private func filedShot(root: String, ocrAfter: String = "cropped text") async throws -> (ShotRow, Deps) {
    var deps = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9, title: "Code")])], native: FakeNative())
    let src = try Fixtures.drop("code.png", into: deps.config.inbox, as: "shot.png")
    let job = try await deps.database.createJob(path: src, originalName: "shot.png", context: nil)
    guard case .done(let shot) = await processJob(job.id, deps: deps) else { throw ShotsError("not filed") }
    deps.native = FakeNative(ocrText: ocrAfter)
    return (shot, deps)
}

/// Replaces the file the way Preview saves: a new file renamed over the old one.
private func overwrite(_ path: String, with fixture: String) throws {
    let temp = URL.temporaryDirectory.appending(path: UUID().uuidString + ".png")
    try FileManager.default.copyItem(atPath: Fixtures.path(fixture), toPath: temp.path)
    _ = try FileManager.default.replaceItemAt(URL(filePath: path), withItemAt: temp)
}

@Suite struct RefreshContentTests {
    @Test func editedFileGetsNewHashSizeAndText() async throws {
        let (shot, deps) = try await filedShot(root: try tempRoot())
        try overwrite(shot.path, with: "error.png")

        let updated = try #require(try await refreshContent(shot, deps: deps))
        #expect(updated.sha256 == (try Files.sha256(shot.path)))
        #expect(updated.sha256 != shot.sha256)
        #expect(updated.ocrText == "cropped text")
        #expect(updated.width == 800 && updated.height == 600)
        // How it was filed stays put.
        #expect(updated.path == shot.path)
        #expect(updated.title == shot.title && updated.category == shot.category)
        #expect(try await deps.database.search("cropped").map(\.shot.id) == [shot.id])
    }

    @Test func unchangedFileIsLeftAlone() async throws {
        let (shot, deps) = try await filedShot(root: try tempRoot())
        #expect(try await refreshContent(shot, deps: deps) == nil)
        #expect(try await deps.database.shot(id: shot.id)?.ocrText == shot.ocrText)
    }

    @Test func missingFileIsLeftAlone() async throws {
        let (shot, deps) = try await filedShot(root: try tempRoot())
        try FileManager.default.removeItem(atPath: shot.path)
        #expect(try await refreshContent(shot, deps: deps) == nil)
    }
}

@Suite struct LibrarySyncTests {
    @Test func picksUpAnEditMadeByAnotherApp() async throws {
        let (shot, deps) = try await filedShot(root: try tempRoot())
        let lastEvent = Mutex<UInt64?>(nil)
        let sync = LibrarySync(deps: deps, latency: .milliseconds(50)) { id in lastEvent.withLock { $0 = id } }
        try await sync.start(since: nil)
        defer { Task { await sync.stop() } }

        try overwrite(shot.path, with: "error.png")
        try await until { try await deps.database.shot(id: shot.id)?.ocrText == "cropped text" }
        #expect(try await deps.database.shot(id: shot.id)?.sha256 == (try Files.sha256(shot.path)))
        #expect(lastEvent.withLock { $0 } != nil)
    }

    @Test func replaysEditsMadeWhileStopped() async throws {
        let (shot, deps) = try await filedShot(root: try tempRoot())
        let lastEvent = Mutex<UInt64?>(nil)
        let first = LibrarySync(deps: deps, latency: .milliseconds(50)) { id in lastEvent.withLock { $0 = id } }
        try await first.start(since: nil)
        // Something to remember an event ID by.
        try Data().write(to: URL(filePath: Paths.join(deps.config.outputRoot, "marker.png")))
        try await until { lastEvent.withLock { $0 } != nil }
        await first.stop()

        try overwrite(shot.path, with: "error.png")
        let second = LibrarySync(deps: deps, latency: .milliseconds(50))
        try await second.start(since: lastEvent.withLock { $0 })
        defer { Task { await second.stop() } }
        try await until { try await deps.database.shot(id: shot.id)?.ocrText == "cropped text" }
    }
}

extension LibrarySyncTests {
    @Test func replaysFromAPointInTime() async throws {
        let before = Date()
        let (shot, deps) = try await filedShot(root: try tempRoot())
        try overwrite(shot.path, with: "error.png")
        try await Task.sleep(for: .milliseconds(200)) // Let fseventsd record it.

        let since = try #require(LibrarySync.eventID(before: before, onVolumeOf: deps.config.outputRoot))
        let sync = LibrarySync(deps: deps, latency: .milliseconds(50))
        try await sync.start(since: since)
        defer { Task { await sync.stop() } }
        try await until { try await deps.database.shot(id: shot.id)?.ocrText == "cropped text" }
    }
}

/// Stands in for the Trash, which tests mustn't fill.
private func removeInstead(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

@Suite struct TrashAndDuplicateTests {
    @Test func duplicateCopiesTheFileAndIndexesIt() async throws {
        let (shot, deps) = try await filedShot(root: try tempRoot())
        let copy = try await duplicate(shot, deps: deps)
        #expect(copy.id != shot.id)
        #expect(copy.title == "Code copy")
        #expect(Paths.dirname(copy.path) == Paths.dirname(shot.path))
        #expect(copy.path.hasSuffix("_code-copy.png"))
        #expect(try Files.sha256(copy.path) == shot.sha256)
        #expect(copy.ocrText == shot.ocrText && copy.category == shot.category && copy.tags == shot.tags)
        #expect(FileManager.default.fileExists(atPath: shot.path))

        // A second copy gets its own name.
        let again = try await duplicate(shot, deps: deps)
        #expect(again.path.hasSuffix("_code-copy-2.png"))
    }

    @Test func trashMovesTheFileAndForgetsTheShot() async throws {
        let (shot, deps) = try await filedShot(root: try tempRoot())
        try await trash(shot, deps: deps, moveToTrash: removeInstead)
        #expect(!FileManager.default.fileExists(atPath: shot.path))
        #expect(try await deps.database.shot(id: shot.id) == nil)
        #expect(try await deps.database.search("hello").isEmpty)
    }

    @Test func trashingAMissingFileStillForgetsIt() async throws {
        let (shot, deps) = try await filedShot(root: try tempRoot())
        try FileManager.default.removeItem(atPath: shot.path)
        try await trash(shot, deps: deps, moveToTrash: removeInstead)
        #expect(try await deps.database.shot(id: shot.id) == nil)
    }
}
