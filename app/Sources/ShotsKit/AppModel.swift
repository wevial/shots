import AppKit
import Foundation
import Observation
import ShotsCore

/// Everything the windows and the menu bar show, and every action they can take.
///
/// Views read properties straight off the model; `@Observable` re-renders exactly the views
/// that read a property when it changes. Views never touch the store or the CLI directly.
@MainActor
@Observable
public final class AppModel {
    // MARK: Setup

    public private(set) var config: ShotsConfig
    /// Why the app can't show anything (bad config, no index). Nil when all is well.
    public private(set) var setupError: String?

    // MARK: What the user picked

    public var scope: SidebarScope = .all {
        didSet { if scope != oldValue { scheduleReload() } }
    }

    /// Bound to `.searchable`. Searching waits for a short pause in typing.
    public var searchText = "" {
        didSet { if searchText != oldValue { scheduleReload(after: .milliseconds(250)) } }
    }

    public var selectedShotID: Shot.ID?

    /// Bound to `.quickLookPreview`; setting a URL opens the Quick Look panel.
    public var quickLookURL: URL?

    // MARK: What the index says

    /// The shots in `scope` matching `searchText`, newest first (or by relevance when searching).
    public internal(set) var shots: [Shot] = []
    public internal(set) var failedJobs: [FailedJob] = []
    /// The five newest shots overall, for the menu bar.
    public internal(set) var recentShots: [Shot] = []
    public internal(set) var counts = ScopeCounts()
    /// True until the first load finishes, so views can tell "loading" from "empty".
    public internal(set) var isLoading = true

    /// Shots with a `recat` running right now. Cards show a spinner while their id is in here.
    public internal(set) var recategorizing: Set<Shot.ID> = []

    /// Progress while older shots are being checked for scratch; nil when no check is running.
    public internal(set) var scratchCheck: ScratchCheck?

    /// The message for the error alert. Set it to nil to dismiss.
    public var lastError: String?

    // MARK: Dependencies

    /// The watcher and pipeline, running in this process.
    public let daemon: DaemonController
    public let loginItem: LaunchAtLogin
    public let system: SystemStatus
    @ObservationIgnored private var store: ShotStore?
    @ObservationIgnored private var lastDataVersion: Int64?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var scratchCheckTask: Task<Void, Never>?

    public init(
        daemon: DaemonController = DaemonController(),
        loginItem: LaunchAtLogin = LaunchAtLogin(),
        config: ShotsConfig = .defaults,
        store: ShotStore? = nil
    ) {
        self.daemon = daemon
        self.loginItem = loginItem
        system = SystemStatus(native: daemon.native)
        self.config = config
        self.store = store
    }

    // MARK: Derived state

    public var selectedShot: Shot? {
        guard let selectedShotID else { return nil }
        return shots.first { $0.id == selectedShotID } ?? recentShots.first { $0.id == selectedShotID }
    }

    /// The configured categories, then any category only the index knows about (renamed or
    /// removed from the config since those shots were filed).
    public var categories: [String] {
        let extra = counts.byCategory.keys.filter { !config.categories.contains($0) }.sorted()
        return config.categories + extra
    }

    /// The menu bar's first line.
    public var statusLine: String {
        switch daemon.state {
        case .idle, .starting: "Starting…"
        case .paused: "Paused"
        case .failed: "Not running"
        case .watching: daemon.filing > 0 ? "Filing \(daemon.filing)…" : "Watching"
        }
    }

    /// The newest filed shot, shown under the status line while watching.
    public var lastFiledLine: String? {
        guard daemon.state == .watching, daemon.filing == 0, let shot = recentShots.first else { return nil }
        return "Last: \(shot.displayTitle)"
    }

    public func isRecategorizing(_ shot: Shot) -> Bool {
        recategorizing.contains(shot.id)
    }

    /// For `.alert(isPresented:)`.
    public var isShowingError: Bool {
        get { lastError != nil }
        set { if !newValue { lastError = nil } }
    }

    // MARK: Loading

    /// Connects to the index and starts watching it for changes. Safe to call more than once.
    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.connect(reloadEngine: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.poll()
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-reads everything shown. For a "Refresh" command.
    public func refresh() async {
        store = nil
        await connect(reloadEngine: false)
    }

    /// Re-reads the config file and restarts the watcher with it.
    public func reloadConfig() async {
        store = nil
        await connect(reloadEngine: true)
    }

    public func togglePaused() async {
        await daemon.togglePaused()
    }

    /// Reads the current scope and search, plus counts, failed jobs and recent shots.
    public func reload() async {
        guard let store else { return }
        let scope = scope, search = searchText
        do {
            let cutoff = config.cleanupCutoff()
            let shots = try await store.shots(in: scope, matching: search, cleanupCutoff: cutoff)
            let counts = try await store.counts(cleanupCutoff: cutoff)
            let failedJobs = try await store.failedJobs()
            let recentShots = try await store.recentShots(limit: 5)
            // A newer reload replaced this one, or the user moved on while it ran (a recat's
            // reload can finish after a scope change); drop the stale result.
            guard !Task.isCancelled, scope == self.scope, search == searchText else { return }
            self.shots = shots
            self.counts = counts
            self.failedJobs = failedJobs
            self.recentShots = recentShots
            setupError = nil
        } catch {
            guard !Task.isCancelled else { return }
            setupError = error.localizedDescription
        }
        isLoading = false
    }

    private func scheduleReload(after delay: Duration? = nil) {
        reloadTask?.cancel()
        reloadTask = Task {
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await reload()
        }
    }

    private func connect(reloadEngine: Bool) async {
        if reloadEngine { await daemon.load() }
        var problems: [String] = []
        if let loaded = daemon.config {
            config = ShotsConfig(loaded, configPath: Config.path())
        } else if case .failed(let message) = daemon.state {
            problems.append(message)
        }

        if store == nil {
            do { store = try ShotStore(path: config.dbPath) } catch { problems.append(error.localizedDescription) }
        }
        if let store {
            lastDataVersion = try? await store.dataVersion()
            await reload()
        } else {
            isLoading = false
        }
        setupError = store == nil ? problems.joined(separator: "\n") : nil
    }

    /// Reloads when the daemon (or a `recat`) has committed since the last look.
    private func poll() async {
        guard let store else {
            await connect(reloadEngine: false) // The index may exist now, e.g. right after install.
            return
        }
        guard let version = try? await store.dataVersion(), version != lastDataVersion else { return }
        lastDataVersion = version
        scheduleReload()
    }

    // MARK: Navigation (used by the menu bar)

    public func show(_ scope: SidebarScope) {
        searchText = ""
        self.scope = scope
    }

    public func show(_ shot: Shot) {
        searchText = ""
        scope = .all
        selectedShotID = shot.id
        // A shot filed seconds ago may not be in `shots` yet when the scope was already All.
        scheduleReload()
    }

    /// The best `limit` full-text matches for `query` in every scope, whatever the sidebar
    /// shows. Empty when there's nothing to search for or no index. For the command palette.
    public func searchAllShots(_ query: String, limit: Int) async -> [Shot] {
        guard let store, FTSQuery.build(query) != nil else { return [] }
        return (try? await store.shots(in: .all, matching: query, limit: limit)) ?? []
    }

    // MARK: Changing shots (in process, through the daemon's database)

    /// Files the shot under `category` by hand. Also how a review is resolved.
    /// Returns the moved shot, or nil when nothing changed or it failed (see `lastError`).
    @discardableResult
    public func recategorize(_ shot: Shot, to category: String) async -> Shot? {
        guard category != shot.category || shot.needsReview else { return nil }
        return await runRecat(on: shot) { daemon in try await daemon.recat(shotID: shot.id, category: category) }
    }

    /// Classifies the shot again with one backend.
    public func rerun(_ shot: Shot, backend: ClassifierBackend) async {
        await runRecat(on: shot) { daemon in try await daemon.recat(shotID: shot.id, backend: backend) }
    }

    @discardableResult
    private func runRecat(on shot: Shot, _ command: (DaemonController) async throws -> RecatResult) async -> Shot? {
        guard daemon.state != .idle else {
            lastError = "The screenshot engine isn't running, so screenshots can't be changed."
            return nil
        }
        guard !recategorizing.contains(shot.id) else { return nil }
        recategorizing.insert(shot.id)
        defer { recategorizing.remove(shot.id) }

        do {
            let result = try await command(daemon)
            // Show the new title/category/path right away; the reload below catches the rest.
            replace(result.shot)
            await reload()
            return result.shot
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: Clean Up

    /// Moves the shots to the Trash. The selection moves on to the next shot, so you can
    /// keep going from the keyboard.
    public func moveToTrash(_ doomed: [Shot]) async {
        guard !doomed.isEmpty else { return }
        guard daemon.state != .idle else {
            lastError = "The screenshot engine isn't running, so screenshots can't be changed."
            return
        }
        let ids = Set(doomed.map(\.id))
        let selectedIndex = selectedShotID.flatMap { id in ids.contains(id) ? shots.firstIndex { $0.id == id } : nil }
        if let url = quickLookURL, doomed.contains(where: { $0.fileURL == url }) { quickLookURL = nil }
        do {
            try await daemon.trash(shotIDs: doomed.map(\.id))
        } catch {
            lastError = error.localizedDescription
        }
        await reload()
        if let selectedIndex {
            selectedShotID = shots.isEmpty ? nil : shots[min(selectedIndex, shots.count - 1)].id
        }
    }

    /// Keeps a shot out of Clean Up for good.
    public func keep(_ shot: Shot) async {
        do {
            try await daemon.keep(shotID: shot.id)
        } catch {
            lastError = error.localizedDescription
        }
        await reload()
    }

    /// Runs the classifier on shots filed before it judged scratch, one at a time. Each one
    /// costs a classifier run, so this only happens when asked.
    public func checkOlderShots() {
        guard scratchCheckTask == nil else { return }
        guard daemon.state != .idle else {
            lastError = "The screenshot engine isn't running, so screenshots can't be checked."
            return
        }
        scratchCheckTask = Task {
            defer {
                scratchCheck = nil
                scratchCheckTask = nil
            }
            var failures: [String] = []
            do {
                let ids = try await daemon.unjudgedShotIDs()
                scratchCheck = ScratchCheck(done: 0, total: ids.count)
                for id in ids {
                    guard !Task.isCancelled else { break }
                    do {
                        try await daemon.judgeScratch(shotID: id)
                    } catch {
                        failures.append(error.localizedDescription)
                    }
                    scratchCheck?.done += 1
                }
            } catch {
                failures.append(error.localizedDescription)
            }
            await reload()
            if let first = failures.first {
                lastError = failures.count == 1 ? first : "\(failures.count) screenshots couldn't be checked. The first error: \(first)"
            }
        }
    }

    public func stopCheckingOlderShots() {
        scratchCheckTask?.cancel()
    }

    /// Crops, turns or flips the shot's file in place, then re-reads it (size, text) into the
    /// index. False when it failed (see `lastError`).
    @discardableResult
    public func save(_ edit: ImageEdit, to shot: Shot) async -> Bool {
        guard fileExists(shot.fileURL) else { return false }
        let url = shot.fileURL
        do {
            try await Task.detached { try edit.apply(toFileAt: url) }.value
        } catch {
            lastError = error.localizedDescription
            return false
        }
        // The library watcher would catch it too, a moment later.
        if daemon.state != .idle, let refreshed = try? await daemon.refreshContent(shotID: shot.id) {
            replace(refreshed)
        }
        await reload()
        return true
    }

    private func replace(_ updated: Shot) {
        // recat moved the file; keep an open Quick Look panel pointing at it.
        if let old = shots.first(where: { $0.id == updated.id }), quickLookURL == old.fileURL {
            quickLookURL = updated.fileURL
        }
        if let index = shots.firstIndex(where: { $0.id == updated.id }) { shots[index] = updated }
        if let index = recentShots.firstIndex(where: { $0.id == updated.id }) { recentShots[index] = updated }
    }

    // MARK: Files

    public func revealInFinder(_ url: URL) {
        guard fileExists(url) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func open(_ url: URL) {
        guard fileExists(url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens Quick Look on `url`, or closes it if it's already showing that file.
    public func quickLook(_ url: URL) {
        guard fileExists(url) else { return }
        quickLookURL = quickLookURL == url ? nil : url
    }

    /// Puts the image on the clipboard: PNG data for pasting into documents, plus the file URL
    /// for apps (Finder, Mail, Messages) that attach files.
    public func copyImage(_ url: URL) {
        guard fileExists(url) else { return }
        guard let data = try? Data(contentsOf: url) else {
            lastError = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let item = NSPasteboardItem()
        if let image = NSImage(data: data), let png = Self.pngData(data, image: image) {
            item.setData(png, forType: .png)
        }
        item.setString(url.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    public func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    public func openInbox() {
        NSWorkspace.shared.open(config.inboxURL)
    }

    // Shot conveniences, so views can write `model.revealInFinder(shot)`.
    public func revealInFinder(_ shot: Shot) { revealInFinder(shot.fileURL) }
    public func open(_ shot: Shot) { open(shot.fileURL) }
    public func quickLook(_ shot: Shot) { quickLook(shot.fileURL) }
    public func copyImage(_ shot: Shot) { copyImage(shot.fileURL) }
    public func copyPath(_ shot: Shot) { copyPath(shot.fileURL) }

    private func fileExists(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        lastError = "\(url.lastPathComponent) is no longer at \(url.deletingLastPathComponent().path). It may have been moved outside Shots."
        return false
    }

    /// Screenshots are PNGs already; anything else gets converted.
    private static func pngData(_ data: Data, image: NSImage) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// How far a check of older shots has got.
public struct ScratchCheck: Equatable, Sendable {
    public var done: Int
    public var total: Int
}
