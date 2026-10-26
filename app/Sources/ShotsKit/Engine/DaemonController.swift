import Foundation
import Observation
import ShotsCore
import ShotsNative

/// Runs the watcher and pipeline inside the app, and owns the one database writer.
///
/// `load()` reads the config and opens the index; `resume()` / `pause()` start and stop
/// the watcher. A paused app can still re-run a classifier on a shot (`recat`).
@MainActor
@Observable
public final class DaemonController {
    public enum State: Equatable, Sendable {
        /// Nothing loaded yet.
        case idle
        case starting
        case watching
        case paused
        /// The config or index couldn't be opened, or the watcher couldn't start.
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Screenshots queued or being filed right now.
    public private(set) var filing = 0
    public private(set) var config: Config?

    public var isPaused: Bool { state == .paused }

    @ObservationIgnored public let native: any Native
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log: Logger
    @ObservationIgnored private var deps: Deps?
    @ObservationIgnored private var daemon: Daemon?
    /// Runs whenever the index is open, paused or not: edits made elsewhere still show up.
    @ObservationIgnored private var librarySync: LibrarySync?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    /// Outlives each `Daemon`, which `load()` replaces, so readers never have to resubscribe.
    @ObservationIgnored private let captures = Broadcast<CaptureEvent>()

    private static let pausedKey = "watchingPaused"
    /// The last FSEvents event `LibrarySync` handled, so edits made while Shots was closed
    /// are caught up at the next launch.
    private static let libraryEventKey = "libraryLastEventID"

    public static let logPath = NSHomeDirectory() + "/Library/Logs/shots/shots.log"

    public init(
        native: any Native = SystemNative(),
        defaults: UserDefaults = .standard,
        log: Logger = Logger(sink: Logger.file(at: DaemonController.logPath))
    ) {
        self.native = native
        self.defaults = defaults
        self.log = log
    }

    /// What happens to each screenshot as it lands, for the "just captured" preview. Live
    /// arrivals only (see `CaptureEvent`); keeps going across reloads, pauses and restarts.
    public func captureEvents() -> AsyncStream<CaptureEvent> {
        captures.stream()
    }

    // MARK: Lifecycle

    /// (Re)reads the config, opens the index and, unless watching is paused, starts watching.
    public func load() async {
        await stopWatching()
        await stopLibrarySync()
        state = .starting
        Toolchain.augmentPath()
        do {
            let config = try Config.load()
            let database: Database
            if let existing = deps?.database, existing.path == config.databasePath {
                database = existing
            } else {
                if let old = deps?.database { await old.close() }
                database = try Database(path: config.databasePath)
            }
            self.config = config
            deps = Deps(config: config, database: database, native: native, log: log)
        } catch {
            state = .failed(errorMessage(error))
            return
        }
        await startLibrarySync()
        if defaults.bool(forKey: Self.pausedKey) {
            state = .paused
        } else {
            await startWatching()
        }
    }

    public func pause() async {
        defaults.set(true, forKey: Self.pausedKey)
        await stopWatching()
        if deps != nil { state = .paused }
    }

    public func resume() async {
        defaults.set(false, forKey: Self.pausedKey)
        if deps == nil {
            await load()
        } else if daemon == nil {
            await startWatching()
        }
    }

    public func togglePaused() async {
        if isPaused { await resume() } else { await pause() }
    }

    /// Stops watching and waits for jobs in flight. Called when the app quits.
    public func shutdown() async {
        await stopWatching()
        await stopLibrarySync()
        await deps?.database.close()
        deps = nil
    }

    private func startWatching() async {
        guard let deps, daemon == nil else { return }
        let daemon = Daemon(deps: deps, onCapture: { [captures] event in captures.yield(event) })
        do {
            try await daemon.start()
        } catch {
            state = .failed(errorMessage(error))
            return
        }
        self.daemon = daemon
        state = .watching
        activityTask = Task { [weak self] in
            while !Task.isCancelled {
                let size = await daemon.queue.size
                self?.filing = size
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let native = native, dataDir = deps.config.dataDir
        Task.detached { await Self.writeStatus(native: native, dataDir: dataDir) }
    }

    private func stopWatching() async {
        activityTask?.cancel()
        activityTask = nil
        filing = 0
        guard let daemon else { return }
        self.daemon = nil
        await daemon.stop()
    }

    private func startLibrarySync() async {
        guard let deps, librarySync == nil else { return }
        // UserDefaults is thread-safe, just not marked Sendable.
        nonisolated(unsafe) let defaults = defaults
        let key = Self.libraryEventKey
        let sync = LibrarySync(deps: deps) { id in
            defaults.set(NSNumber(value: id), forKey: key)
        }
        // The first time, catch up on the last month: edits made before this version.
        let since = (defaults.object(forKey: key) as? NSNumber)?.uint64Value
            ?? LibrarySync.eventID(before: .now.addingTimeInterval(-30 * 86_400), onVolumeOf: deps.config.outputRoot)
        do {
            try await sync.start(since: since)
            librarySync = sync
        } catch {
            log.error("library watcher error", ["error": .string(errorMessage(error))])
        }
    }

    private func stopLibrarySync() async {
        guard let librarySync else { return }
        self.librarySync = nil
        await librarySync.stop()
    }

    /// `daemon-status.json`, which `shots doctor` reads: TCC grants belong to this process.
    private static func writeStatus(native: any Native, dataDir: String) async {
        func capture(_ value: () async throws -> JSONValue) async -> JSONValue {
            do { return try await value() } catch { return ["error": .string(errorMessage(error))] }
        }
        let permissions = await capture { try await native.permissions().json }
        let fm = await capture { try await native.fmStatus().json }
        let fields: JSONObject = [
            "pid": JSONValue(Int(ProcessInfo.processInfo.processIdentifier)),
            "execPath": .string(Bundle.main.executablePath ?? CommandLine.arguments[0]),
            "permissions": permissions,
            "fm": fm,
        ]
        try? DaemonStatus.write(dataDir: dataDir, fields: fields)
    }

    // MARK: Changing shots

    /// Re-classifies (`backend`) or hand-files (`category`) a shot in process.
    public func recat(shotID: Int64, backend: ClassifierBackend? = nil, category: String? = nil) async throws -> RecatResult {
        guard let deps else { throw ShotsError("The screenshot engine isn't running, so screenshots can't be changed.") }
        guard let row = try await deps.database.shot(id: shotID) else { throw ShotsError("That screenshot is no longer in the index.") }
        var options = RecatOptions(category: category)
        if let name = backend?.backendName {
            options.backends = [createBackend(name, config: deps.config, native: native)]
        }
        return RecatResult(try await ShotsCore.recat(row, options: options, deps: deps))
    }

    /// Moves the shots' files to the Trash and drops them from the index.
    public func trash(shotIDs: [Int64]) async throws {
        let deps = try runningDeps()
        for id in shotIDs {
            guard let row = try await deps.database.shot(id: id) else { continue }
            try await trashShot(row, database: deps.database)
        }
    }

    /// Keeps a shot out of Clean Up for good.
    public func keep(shotID: Int64) async throws {
        try await runningDeps().database.keep(shotID)
    }

    /// Runs the classifier chain on a shot filed before it judged scratch, storing only the verdict.
    public func judgeScratch(shotID: Int64) async throws {
        let deps = try runningDeps()
        guard let row = try await deps.database.shot(id: shotID) else { return }
        _ = try await ShotsCore.judgeScratch(row, deps: deps)
    }

    /// Shots filed before the classifier judged scratch, newest first.
    public func unjudgedShotIDs() async throws -> [Int64] {
        try await runningDeps().database.unjudgedShots().map(\.id)
    }

    private func runningDeps() throws -> Deps {
        guard let deps else { throw ShotsError("The screenshot engine isn't running, so screenshots can't be changed.") }
        return deps
    }

    /// Re-reads a shot whose file was just edited: hash, size and OCR text. Nil when the
    /// bytes are unchanged.
    public func refreshContent(shotID: Int64) async throws -> Shot? {
        guard let deps else { throw ShotsError("The screenshot engine isn't running, so screenshots can't be changed.") }
        guard let row = try await deps.database.shot(id: shotID) else { throw ShotsError("That screenshot is no longer in the index.") }
        return try await ShotsCore.refreshContent(row, deps: deps).map(Shot.init(row:))
    }
}

/// The search path for tools the classifiers shell out to (`claude`, `codex`).
public enum Toolchain {
    /// Apps started from Finder or at login get a bare PATH. Add the usual install
    /// locations to this process's PATH, which child processes inherit.
    public static func augmentPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var parts = current.split(separator: ":").map(String.init)
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"].reversed()
        where !parts.contains(extra) {
            parts.insert(extra, at: 0)
        }
        setenv("PATH", parts.joined(separator: ":"), 1)
    }
}
