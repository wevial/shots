import Foundation

/// Why a path is being looked at, which decides what detection does with it.
public enum ScanMode: String, Sendable {
    /// A watcher event just fired: capture live app context before anything slow.
    case event
    /// The periodic safety net: new files only, no context (we can't know when they landed).
    case scan
    /// Startup or a retry timer: also re-queue failed files under `maxAttempts`.
    case retry
}

/// What the daemon is doing, for a menu bar or status window. Every change is published
/// through `Daemon.snapshots()`.
public struct DaemonSnapshot: Sendable, Equatable {
    public enum State: String, Sendable {
        case stopped, watching, paused
    }

    public struct Failure: Sendable, Equatable {
        /// The inbox file it was about, when there was one.
        public var path: String?
        public var message: String
        public var at: Date
    }

    public var state: State
    public var inbox: String
    /// Jobs queued or being processed.
    public var queued: Int
    /// Inbox paths being processed right now.
    public var processing: [String]
    /// Screenshots filed since `start()`.
    public var filedCount: Int
    public var lastFiled: ShotRow?
    public var lastError: Failure?

    public init(
        state: State = .stopped, inbox: String, queued: Int = 0, processing: [String] = [], filedCount: Int = 0,
        lastFiled: ShotRow? = nil, lastError: Failure? = nil
    ) {
        self.state = state
        self.inbox = inbox
        self.queued = queued
        self.processing = processing
        self.filedCount = filedCount
        self.lastFiled = lastFiled
        self.lastError = lastError
    }
}

/// Watches the inbox and feeds the pipeline. Ported from src/daemon.ts: any watcher event
/// triggers a debounced rescan (event names aren't trustworthy across the rename macOS does),
/// a periodic rescan is the safety net, interrupted jobs resume at start, and failed jobs
/// retry after `retryDelayMs` until `maxAttempts`.
///
/// The actor owns the in-flight set, so a path is never queued twice; the `Database` actor
/// is the only thing that writes the index.
public actor Daemon {
    public nonisolated let queue: AsyncQueue
    private let deps: Deps
    private let rescanInterval: Duration
    private let onCapture: @Sendable (CaptureEvent) -> Void

    private var snapshot: DaemonSnapshot
    private var observers: [UUID: AsyncStream<DaemonSnapshot>.Continuation] = [:]

    /// Paths with a job queued or running, or a detection in progress.
    private var inflight: Set<String> = []
    private var processing: Set<String> = []
    private var queued = 0
    private var watcher: DirectoryWatcher?
    /// Timers and scans the daemon started itself; `stop()` cancels and awaits them.
    private var tasks: [UUID: (task: Task<Void, Never>, isRetry: Bool)] = [:]
    private var debounce: UUID?
    /// Retry timers that came due while paused; they run on `resume()`.
    private var deferredRetries: Set<String> = []

    /// - Parameter onCapture: hears what happens to each live arrival (see `CaptureEvent`).
    ///   Called from the job's task, in order, so it must be quick and thread-safe.
    public init(deps: Deps, rescanInterval: Duration = .seconds(60), onCapture: @escaping @Sendable (CaptureEvent) -> Void = { _ in }) {
        self.deps = deps
        self.rescanInterval = rescanInterval
        self.onCapture = onCapture
        self.queue = AsyncQueue(concurrency: deps.config.concurrency)
        self.snapshot = DaemonSnapshot(inbox: deps.config.inbox)
    }

    // MARK: Status

    public var status: DaemonSnapshot { snapshot }

    /// The current snapshot, then every change. A slow reader only ever sees the latest.
    public func snapshots() -> AsyncStream<DaemonSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: DaemonSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        continuation.yield(snapshot)
        observers[id] = continuation
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func publish(_ change: (inout DaemonSnapshot) -> Void = { _ in }) {
        change(&snapshot)
        snapshot.queued = queued
        snapshot.processing = processing.sorted()
        for observer in observers.values { observer.yield(snapshot) }
    }

    private func recordError(_ message: String, path: String?) {
        publish { $0.lastError = .init(path: path, message: message, at: Date()) }
    }

    // MARK: Lifecycle

    /// Creates the inbox, resumes interrupted and pending jobs, starts watching, and runs a
    /// first `.retry` scan. Does nothing when already started.
    public func start() async throws {
        guard snapshot.state == .stopped else { return }
        let config = deps.config, db = deps.database, log = deps.log
        // State first: everything below awaits, and a second start() must see this one.
        publish {
            $0.state = .watching
            $0.filedCount = 0
            $0.lastError = nil
        }
        inflight = []
        deferredRetries = []
        await queue.resume()
        do {
            try FileManager.default.createDirectory(atPath: config.inbox, withIntermediateDirectories: true)
            let reset = try await db.resetInterrupted()
            if reset > 0 { log.info("resumed interrupted jobs", ["count": JSONValue(reset)]) }
            try await resumePending()
            try startWatcher()
        } catch {
            await stop()
            throw error
        }
        spawn { await $0.scan(.retry) }
        startPeriodicScan()
        log.info("watching", [
            "inbox": .string(config.inbox), "backends": JSONValue(config.backends.map(\.rawValue)),
            "allowCloud": .bool(config.allowCloud), "concurrency": JSONValue(config.concurrency),
        ])
    }

    /// Stops watching and cancels timers, then waits for running jobs to finish. Jobs that
    /// were queued but not started stay `pending` in the index and resume at the next start.
    public func stop() async {
        guard snapshot.state != .stopped else { return }
        publish { $0.state = .stopped }
        stopWatcher()
        await cancelTasks(includingRetries: true)
        let dropped = await queue.dropWaiting()
        queued -= dropped
        await queue.onIdle()
        deferredRetries = []
        publish()
    }

    /// Stops detecting files and starting queued jobs; a job already running finishes.
    /// Files that land meanwhile are picked up by `resume()`.
    public func pause() async {
        guard snapshot.state == .watching else { return }
        publish { $0.state = .paused }
        stopWatcher()
        // Retry timers keep running; one that comes due while paused waits for resume().
        await cancelTasks(includingRetries: false)
        await queue.pause()
        deps.log.info("paused")
    }

    public func resume() async {
        guard snapshot.state == .paused else { return }
        publish { $0.state = .watching }
        await queue.resume()
        do {
            try startWatcher()
        } catch {
            deps.log.error("watcher error", ["error": .string(errorMessage(error))])
            recordError(errorMessage(error), path: nil)
        }
        let retries = deferredRetries
        deferredRetries = []
        spawn { daemon in
            for path in retries.sorted() { await daemon.detect(path, mode: .retry) }
            await daemon.scan(.scan)
        }
        startPeriodicScan()
        deps.log.info("resumed")
    }

    private func resumePending() async throws {
        let db = deps.database
        for job in try await db.pendingJobs() {
            guard FileManager.default.fileExists(atPath: job.inboxPath) else {
                try await db.finishJob(job.id, status: .failed, error: "file disappeared before processing")
                continue
            }
            inflight.insert(job.inboxPath)
            await enqueue(job.id, job.inboxPath)
        }
    }

    // MARK: Watching

    private func startWatcher() throws {
        try FileManager.default.createDirectory(atPath: deps.config.inbox, withIntermediateDirectories: true)
        // Event names aren't trustworthy (macOS writes ".Screenshot…" then renames it, and
        // watchers report the rename under either name): any event just schedules a rescan.
        watcher = try DirectoryWatcher(path: deps.config.inbox) { [weak self] in
            guard let self else { return }
            Task { await self.scheduleScan() }
        }
    }

    /// Watcher events can be coalesced or missed (sleep/wake, bursts); a periodic scan is the safety net.
    private func startPeriodicScan() {
        let interval = rescanInterval
        spawn { daemon in
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                await daemon.periodicScan()
            }
        }
    }

    private func stopWatcher() {
        watcher?.cancel()
        watcher = nil
    }

    /// The watcher follows the folder it opened. If the inbox was deleted or replaced,
    /// recreate it and watch the new one.
    private func checkWatcher() {
        guard snapshot.state == .watching else { return }
        if let watcher, watcher.isWatching(deps.config.inbox) { return }
        stopWatcher()
        do {
            try startWatcher()
            deps.log.warn("inbox was replaced; watching it again", ["inbox": .string(deps.config.inbox)])
        } catch {
            deps.log.error("watcher error", ["error": .string(errorMessage(error))])
            recordError(errorMessage(error), path: nil)
        }
    }

    private func scheduleScan() {
        guard snapshot.state == .watching, debounce == nil else { return }
        debounce = spawn { daemon in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            await daemon.debouncedScan()
        }
    }

    private func debouncedScan() async {
        debounce = nil
        checkWatcher()
        await scan(.event)
    }

    private func periodicScan() async {
        guard snapshot.state == .watching else { return }
        checkWatcher()
        await scan(.scan)
    }

    // MARK: Detection

    /// Looks at every file in the inbox.
    public func scan(_ mode: ScanMode = .scan) async {
        let inbox = deps.config.inbox
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: inbox) else { return }
        await withTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask { await self.detect(Paths.join(inbox, name), mode: mode) }
            }
        }
    }

    /// One path, one decision: new job, resume, retry, or nothing.
    ///   - event: a watcher event just fired: capture live app context (before anything slow)
    ///   - scan: periodic safety net: new files only, no context
    ///   - retry: startup or retry timer: also re-queue failed files under maxAttempts
    public func detect(_ path: String, mode: ScanMode = .event) async {
        guard Files.isCandidate(path), !inflight.contains(path), FileManager.default.fileExists(atPath: path) else { return }
        if snapshot.state == .paused {
            if mode == .retry { deferredRetries.insert(path) }
            return
        }
        inflight.insert(path)
        let config = deps.config, db = deps.database, native = deps.native, log = deps.log
        do {
            let age = Date().timeIntervalSince(try Files.capturedAt(path)) * 1000
            let liveContext = mode == .event && age <= Double(config.contextMaxAgeMs)
            // Started first: the frontmost app changes quickly, the database lookups can wait.
            let contextTask: Task<AppContext?, Never>? = liveContext ? Task.detached { try? await native.context() } : nil

            let latest = try await db.latestJob(forPath: path)
            if let latest, latest.status == .pending || latest.status == .processing {
                await enqueue(latest.id, path)
                return
            }
            let retryable = latest.map { $0.status == .failed && $0.attempts < config.maxAttempts } ?? false
            if let latest, !(retryable && mode == .retry) {
                // Already decided (or waiting on its retry timer). Only different bytes under the same name are new work.
                if try latest.sha256 == nil || latest.sha256 == Files.sha256(path) {
                    inflight.remove(path)
                    return
                }
            }
            if retryable, mode == .retry, let latest {
                try await db.requeueJob(latest.id) // keeps the context captured when the file first landed
                log.info("retrying", ["path": .string(path), "job": JSONValue(latest.id), "attempt": JSONValue(latest.attempts + 1)])
                await enqueue(latest.id, path)
                return
            }
            let context = await contextTask?.value ?? nil
            let job = try await db.createJob(path: path, originalName: Paths.basename(path), context: context)
            log.info("detected", [
                "path": .string(path), "job": JSONValue(job.id), "app": JSONValue(context?.bundleId), "mode": .string(mode.rawValue),
            ])
            await enqueue(job.id, path)
        } catch {
            inflight.remove(path)
            log.error("detect failed", ["path": .string(path), "error": .string(errorMessage(error))])
            recordError(errorMessage(error), path: path)
        }
    }

    // MARK: Jobs

    private func enqueue(_ jobId: Int64, _ path: String) async {
        queued += 1
        publish()
        let deps = deps, onCapture = onCapture
        await queue.push { [self] in
            await jobStarted(path)
            let result = await processJob(jobId, deps: deps, onEvent: onCapture)
            await jobFinished(path, result)
        }
    }

    private func jobStarted(_ path: String) {
        processing.insert(path)
        publish()
    }

    private func jobFinished(_ path: String, _ result: JobResult) {
        inflight.remove(path)
        processing.remove(path)
        queued -= 1
        switch result {
        case .done(let shot):
            publish {
                $0.filedCount += 1
                $0.lastFiled = shot
            }
        case .skipped:
            publish()
        case .failed(let error, let retry):
            recordError(error, path: path)
            if retry, snapshot.state != .stopped {
                let delay = deps.config.retryDelay
                spawn(isRetry: true) { daemon in
                    do { try await Task.sleep(for: delay) } catch { return }
                    await daemon.detect(path, mode: .retry)
                }
            }
        }
    }

    // MARK: Tasks

    @discardableResult
    private func spawn(isRetry: Bool = false, _ work: @escaping @Sendable (Daemon) async -> Void) -> UUID {
        let id = UUID()
        // Runs on this actor, so it can't finish before it's registered below.
        let task = Task {
            await work(self)
            self.taskEnded(id)
        }
        tasks[id] = (task, isRetry)
        return id
    }

    private func taskEnded(_ id: UUID) {
        tasks[id] = nil
        if debounce == id { debounce = nil }
    }

    /// Cancels timers and scans and waits for them: a scan in progress finishes its
    /// detections first, so nothing touches the index after `stop()` returns.
    private func cancelTasks(includingRetries: Bool) async {
        while let (id, entry) = tasks.first(where: { includingRetries || !$0.value.isRetry }) {
            entry.task.cancel()
            await entry.task.value
            tasks[id] = nil
        }
        debounce = nil
    }
}

/// A kqueue watch on one directory (DispatchSource). It reports that *something* changed
/// in it, which is all the daemon wants to know.
private final class DirectoryWatcher {
    private let source: any DispatchSourceFileSystemObject
    private let device: dev_t
    private let inode: ino_t

    private static let queue = DispatchQueue(label: "shots.inbox-watcher")

    init(path: String, onChange: @escaping @Sendable () -> Void) throws {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { throw ShotsError("cannot watch \(path): \(String(cString: strerror(errno)))") }
        var info = stat()
        fstat(fd, &info)
        device = info.st_dev
        inode = info.st_ino
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link, .extend, .attrib], queue: Self.queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    /// Whether `path` is still the directory this watches (not deleted, moved or replaced).
    func isWatching(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_dev == device && info.st_ino == inode
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
