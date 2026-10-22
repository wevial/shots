import Foundation
import Testing
@testable import ShotsCore

// Ported from test/daemon.test.ts, plus pause/resume and status snapshots.

/// Image files anywhere under `dir`.
private func filed(_ dir: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: dir) else { return [] }
    return enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".png") }
}

/// Like `Fixtures.drop`, but writes the bytes so the file is born now (a copy keeps the
/// fixture's creation date, which would be too old for live context capture).
@discardableResult
private func drop(_ fixture: String, into dir: String, as name: String) throws -> String {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let dest = Paths.join(dir, name)
    try Data(contentsOf: URL(filePath: Fixtures.path(fixture))).write(to: URL(filePath: dest))
    return dest
}

/// `start()` runs its first scan in the background. A file dropped before that scan looks is
/// found by it, without live context, so it isn't a live arrival.
private func afterStartupScan() async throws {
    try await Task.sleep(for: .milliseconds(200))
}

private func inboxFiles(_ deps: Deps) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: deps.config.inbox)
}

@Suite(.serialized) struct DaemonTests {
    @Test func picksUpNewFilesWithContextAndIgnoresHiddenTempFiles() async throws {
        let root = try tempRoot()
        let native = FakeNative()
        let backend = MockBackend("apple", [ok("code", 0.9)])
        let deps = try testDeps(root, backends: [backend], native: native)
        let daemon = Daemon(deps: deps)
        try await daemon.start()
        // macOS writes a hidden temp file then renames it into place.
        let tmp = try drop("code.png", into: deps.config.inbox, as: ".Screenshot temp.png")
        try await Task.sleep(for: .milliseconds(300))
        #expect(native.contextCalls == 0)
        try FileManager.default.moveItem(atPath: tmp, toPath: Paths.join(deps.config.inbox, "Screenshot 1.png"))
        let codeDir = Paths.join(deps.config.outputRoot, "code")
        try await until { filed(codeDir).count == 1 }
        await daemon.stop()
        #expect(native.contextCalls == 1)
        #expect(backend.calls.first?.appContext?.bundleId == "com.microsoft.VSCode")
        #expect(try inboxFiles(deps).isEmpty)
        let status = await daemon.status
        #expect(status.state == .stopped)
        #expect(status.filedCount == 1)
        #expect(status.lastFiled?.category == "code")
        #expect(status.queued == 0)
    }

    @Test func burstsQueueWithBoundedConcurrency() async throws {
        let root = try tempRoot()
        let backend = MockBackend("claude-code", [ok("code", 0.9)], cloud: true, delay: .milliseconds(40))
        let deps = try testDeps(root, backends: [backend], native: FakeNative(), ["concurrency": 2])
        let daemon = Daemon(deps: deps)
        try await daemon.start()
        for (i, fixture) in ["code.png", "error.png", "receipt.png", "blank.png"].enumerated() {
            try drop(fixture, into: deps.config.inbox, as: "Screenshot \(i).png")
        }
        let codeDir = Paths.join(deps.config.outputRoot, "code")
        try await until(timeout: .seconds(8)) { filed(codeDir).count == 4 }
        await daemon.stop()
        #expect(backend.calls.count == 4) // same title, same minute: names are reserved, so no move collides
        #expect(backend.maxActive <= 2)
    }

    @Test func survivesARestart() async throws {
        let root = try tempRoot()
        let first = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9)])], native: FakeNative())
        // Simulate a crash mid-job: a file whose job is stuck in "processing".
        let stuck = try drop("error.png", into: first.config.inbox, as: "Screenshot stuck.png")
        let job = try await first.database.createJob(path: stuck, originalName: "Screenshot stuck.png", context: nil)
        _ = try await first.database.startJob(job.id)
        await first.database.close()

        let backend = MockBackend("apple", [ok("errors", 0.9)])
        let second = try testDeps(root, backends: [backend], native: FakeNative())
        let d2 = Daemon(deps: second)
        try await d2.start()
        let errorsDir = Paths.join(second.config.outputRoot, "errors")
        try await until { filed(errorsDir).count == 1 }
        await d2.stop()
        let row = try #require(try await second.database.job(id: job.id))
        #expect(row.status == .done)
        #expect(row.attempts == 2)
        await second.database.close()

        let again = MockBackend("apple", [ok("code", 0.9)])
        let third = try testDeps(root, backends: [again], native: FakeNative())
        let d3 = Daemon(deps: third)
        try await d3.start()
        await d3.scan()
        await d3.stop()
        #expect(again.calls.isEmpty)
        #expect(try await third.database.stats().shots == 1)
    }

    @Test func filesAlreadyInTheInboxGetNoStaleContext() async throws {
        let root = try tempRoot()
        let native = FakeNative()
        let backend = MockBackend("apple", [ok("receipts", 0.9)])
        let deps = try testDeps(root, backends: [backend], native: native)
        try drop("receipt.png", into: deps.config.inbox, as: "Screenshot old.png")
        let daemon = Daemon(deps: deps)
        try await daemon.start()
        let receiptsDir = Paths.join(deps.config.outputRoot, "receipts")
        try await until { filed(receiptsDir).count == 1 }
        await daemon.stop()
        #expect(native.contextCalls == 0)
        #expect(backend.calls.first.map { $0.appContext == nil } == true)
    }

    @Test func newArrivalsDontRequeueAFailedFileEarlyOrOverwriteItsContext() async throws {
        let root = try tempRoot()
        let native = FakeNative(context: appContext(bundleId: "com.later.App", appName: "Later"))
        let backend = MockBackend("apple", [fail(.error, "down"), ok("code", 0.9)])
        let deps = try testDeps(root, backends: [backend], native: native, ["retryDelayMs": 60_000])
        let failing = try drop("error.png", into: deps.config.inbox, as: "Screenshot first.png")
        let job = try await deps.database.createJob(path: failing, originalName: "Screenshot first.png", context: appContext(bundleId: "com.first.App"))
        let daemon = Daemon(deps: deps)
        try await daemon.start()
        let db = deps.database
        try await until { try await db.job(id: job.id)?.status == .failed }
        try drop("code.png", into: deps.config.inbox, as: "Screenshot second.png")
        let codeDir = Paths.join(deps.config.outputRoot, "code")
        try await until { filed(codeDir).count == 1 }
        await daemon.stop()
        #expect(backend.calls.count == 2)
        #expect(backend.calls.last?.appContext?.bundleId == "com.later.App")
        let row = try #require(try await db.job(id: job.id))
        #expect(row.status == .failed)
        #expect(row.attempts == 1)
        #expect(row.context?.bundleId == "com.first.App")
        #expect(await daemon.status.lastError?.message.contains("all backends failed") == true)
    }

    @Test func failedFilesAreRetriedThenLeftInTheInbox() async throws {
        let root = try tempRoot()
        let backend = MockBackend("apple", [fail(.error, "down"), fail(.error, "down"), ok("code", 0.9)])
        let deps = try testDeps(root, backends: [backend], native: FakeNative(), ["maxAttempts": 2])
        let daemon = Daemon(deps: deps)
        try await daemon.start()
        let src = try drop("code.png", into: deps.config.inbox, as: "Screenshot flaky.png")
        try await until { backend.calls.count >= 2 }
        try await Task.sleep(for: .milliseconds(200))
        await daemon.stop()
        #expect(backend.calls.count == 2)
        #expect(FileManager.default.fileExists(atPath: src))
        let row = try #require(try await deps.database.latestJob(forPath: src))
        #expect(row.status == .failed)
        #expect(row.attempts == 2)
    }

    @Test func periodicRescanCatchesWhatTheWatcherMissed() async throws {
        let root = try tempRoot()
        let backend = MockBackend("apple", [ok("code", 0.9)])
        let deps = try testDeps(root, backends: [backend], native: FakeNative())
        let daemon = Daemon(deps: deps, rescanInterval: .milliseconds(200))
        try await daemon.start()
        // Replacing the inbox folder leaves the watcher on the old one; the rescan re-watches.
        let inbox = deps.config.inbox
        try FileManager.default.removeItem(atPath: inbox)
        try await Task.sleep(for: .milliseconds(400))
        try drop("code.png", into: inbox, as: "Screenshot late.png")
        let codeDir = Paths.join(deps.config.outputRoot, "code")
        try await until { filed(codeDir).count == 1 }
        await daemon.stop()
    }

    @Test func pausedDaemonWaitsForResume() async throws {
        let root = try tempRoot()
        let backend = MockBackend("apple", [ok("code", 0.9)])
        let deps = try testDeps(root, backends: [backend], native: FakeNative())
        let daemon = Daemon(deps: deps)
        try await daemon.start()
        await daemon.pause()
        #expect(await daemon.status.state == .paused)
        let src = try drop("code.png", into: deps.config.inbox, as: "Screenshot paused.png")
        await daemon.detect(src)
        try await Task.sleep(for: .milliseconds(300))
        #expect(backend.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: src))

        await daemon.resume()
        let codeDir = Paths.join(deps.config.outputRoot, "code")
        try await until { filed(codeDir).count == 1 }
        await daemon.stop()
        #expect(backend.calls.count == 1)
    }

    @Test func snapshotsStreamChanges() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9)])], native: FakeNative())
        let daemon = Daemon(deps: deps)
        let stream = await daemon.snapshots()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.state == .stopped)
        try await daemon.start()
        try drop("code.png", into: deps.config.inbox, as: "Screenshot streamed.png")
        var filed: ShotRow?
        while filed == nil, let snapshot = await iterator.next() {
            filed = snapshot.lastFiled
        }
        #expect(filed?.originalName == "Screenshot streamed.png")
        await daemon.stop()
    }

    @Test func liveArrivalEmitsLandedThenFiled() async throws {
        let root = try tempRoot()
        let deps = try testDeps(root, backends: [MockBackend("apple", [ok("code", 0.9)])], native: FakeNative())
        let recorder = EventRecorder()
        let daemon = Daemon(deps: deps, onCapture: recorder.record)
        try await daemon.start()
        try await afterStartupScan()
        let src = try drop("code.png", into: deps.config.inbox, as: "Screenshot live.png")
        try await until { recorder.events.count == 2 }
        await daemon.stop()
        guard case .landed(let jobID, let path, let copied) = recorder.events[0],
              case .filed(let filedID, let shot) = recorder.events[1] else {
            Issue.record("expected landed then filed, got \(recorder.events)"); return
        }
        #expect(path == src)
        #expect(copied)
        #expect(filedID == jobID)
        #expect(shot.originalName == "Screenshot live.png")
    }

    @Test func startupScanAndRetriesEmitNothing() async throws {
        let root = try tempRoot()
        let backend = MockBackend("apple", [ok("receipts", 0.9)])
        let deps = try testDeps(root, backends: [backend], native: FakeNative())
        try drop("receipt.png", into: deps.config.inbox, as: "Screenshot old.png")
        let recorder = EventRecorder()
        let daemon = Daemon(deps: deps, onCapture: recorder.record)
        try await daemon.start()
        try await until { filed(Paths.join(deps.config.outputRoot, "receipts")).count == 1 }
        await daemon.stop()
        #expect(recorder.events.isEmpty)
    }

    @Test func liveFailureEmitsFailedAndItsRetryStaysQuiet() async throws {
        let root = try tempRoot()
        let backend = MockBackend("apple", [fail(.error, "down"), ok("code", 0.9)])
        let deps = try testDeps(root, backends: [backend], native: FakeNative())
        let recorder = EventRecorder()
        let daemon = Daemon(deps: deps, onCapture: recorder.record)
        try await daemon.start()
        try await afterStartupScan()
        try drop("code.png", into: deps.config.inbox, as: "Screenshot flaky.png")
        // The retry (after retryDelayMs) files it.
        try await until { filed(Paths.join(deps.config.outputRoot, "code")).count == 1 }
        await daemon.stop()
        #expect(backend.calls.count == 2)
        guard recorder.events.count == 2, case .landed(let jobID, _, _) = recorder.events[0],
              case .failed(let failedID, let error) = recorder.events[1] else {
            Issue.record("expected landed then failed, got \(recorder.events)"); return
        }
        #expect(failedID == jobID)
        #expect(error.contains("all backends failed"))
    }

    @Test func stopLeavesQueuedJobsPendingForTheNextStart() async throws {
        let root = try tempRoot()
        let backend = MockBackend("apple", [ok("code", 0.9)], delay: .milliseconds(300))
        let deps = try testDeps(root, backends: [backend], native: FakeNative(), ["concurrency": 1])
        for i in 0..<3 { try drop(["code.png", "error.png", "receipt.png"][i], into: deps.config.inbox, as: "Screenshot \(i).png") }
        let daemon = Daemon(deps: deps)
        try await daemon.start()
        try await until { backend.calls.count == 1 }
        await daemon.stop()
        #expect(backend.calls.count == 1)
        #expect(try await deps.database.pendingJobs().count == 2)

        try await daemon.start()
        let codeDir = Paths.join(deps.config.outputRoot, "code")
        try await until { filed(codeDir).count == 3 }
        await daemon.stop()
        #expect(backend.calls.count == 3)
    }
}
