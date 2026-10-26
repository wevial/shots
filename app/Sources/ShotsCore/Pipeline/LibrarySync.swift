import CoreServices
import Foundation
import Synchronization

/// Keeps the index in step with filed screenshots that another app edits in place (cropped
/// in Preview, say): watches everything under `outputRoot` except the inbox and runs
/// `refreshContent` on any indexed file that changes.
///
/// FSEvents, so `start(since:)` also replays what changed while the app wasn't running;
/// `onEventID` hears the last event handled, for the caller to keep for next time.
public actor LibrarySync {
    private let deps: Deps
    private let latency: Duration
    private let onEventID: @Sendable (UInt64) -> Void
    private var stream: FileEventStream?
    /// Paths that changed since the last flush; an editor's save is several events.
    private var pending: Set<String> = []
    private var flush: Task<Void, Never>?
    /// The newest event in `pending`, reported once those paths are refreshed.
    private var lastEventID: UInt64?

    public init(deps: Deps, latency: Duration = .seconds(1), onEventID: @escaping @Sendable (UInt64) -> Void = { _ in }) {
        self.deps = deps
        self.latency = latency
        self.onEventID = onEventID
    }

    /// - Parameter since: the last event ID from an earlier run, or nil for changes from now on.
    public func start(since: UInt64?) throws {
        guard stream == nil else { return }
        let root = deps.config.outputRoot
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // FSEvents reports real paths (`/private/var/…` for `/var/…`); the index has the configured ones.
        let realRoot = Self.realPath(root)
        stream = try FileEventStream(path: root, since: since, latency: latency.seconds) { [weak self] paths, lastID in
            guard let self else { return }
            let mapped = paths.map { $0.hasPrefix(realRoot + "/") ? root + $0.dropFirst(realRoot.count) : $0 }
            Task { await self.received(mapped, lastID: lastID) }
        }
    }

    /// Stops watching and waits for a refresh in progress.
    public func stop() async {
        stream?.cancel()
        stream = nil
        pending = []
        flush?.cancel()
        await flush?.value
        flush = nil
    }

    /// The last event on `path`'s volume before `date`: a `since` that replays from then on.
    /// Nil when the volume can't be read.
    public static func eventID(before date: Date, onVolumeOf path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FSEventsGetLastEventIdForDeviceBeforeTime(info.st_dev, date.timeIntervalSinceReferenceDate)
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func received(_ paths: [String], lastID: UInt64) {
        guard stream != nil else { return }
        // Recently Deleted's files only ever move in and out.
        let skipped = [deps.config.inbox + "/", deletedFolder(deps.config) + "/"]
        pending.formUnion(paths.filter { path in Files.isCandidate(path) && !skipped.contains { path.hasPrefix($0) } })
        lastEventID = lastID
        guard flush == nil else { return }
        flush = Task { await self.refreshPending() }
    }

    private func refreshPending() async {
        while !pending.isEmpty, !Task.isCancelled {
            let paths = pending
            pending = []
            for path in paths.sorted() where !Task.isCancelled {
                do {
                    // Most events are shots being filed or moved, which the index already knows about.
                    guard let shot = try await deps.database.shot(atPath: path) else { continue }
                    try await refreshContent(shot, deps: deps)
                } catch {
                    deps.log.warn("refresh failed", ["path": .string(path), "error": .string(errorMessage(error))])
                }
            }
        }
        if !Task.isCancelled, let lastEventID { onEventID(lastEventID) }
        flush = nil
    }
}

/// An FSEvents stream of file-level changes under one folder, delivered on a private queue.
private final class FileEventStream: Sendable {
    typealias Handler = @Sendable (_ paths: [String], _ lastEventID: UInt64) -> Void

    /// Owned by the stream (retained in its context), so a callback in flight never outlives it.
    private final class Box {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    private nonisolated(unsafe) let stream: FSEventStreamRef
    private let isCancelled = Mutex(false)
    private static let queue = DispatchQueue(label: "shots.library-watcher")

    init(path: String, since: UInt64?, latency: TimeInterval, handler: @escaping Handler) throws {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(Box(handler)).toOpaque(),
            retain: nil, release: { Unmanaged<Box>.fromOpaque($0!).release() }, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, ids in
            guard let info, count > 0 else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes makes `paths` a CFArray of CFStrings.
            let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
            box.handler(list, ids[count - 1])
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else {
            Unmanaged<Box>.fromOpaque(context.info!).release()
            throw ShotsError("cannot watch \(path)")
        }
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw ShotsError("cannot watch \(path)")
        }
        self.stream = stream
    }

    func cancel() {
        let wasCancelled = isCancelled.withLock { cancelled in
            defer { cancelled = true }
            return cancelled
        }
        guard !wasCancelled else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
    }

    deinit {
        cancel()
        FSEventStreamRelease(stream)
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for APIs that take one.
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
