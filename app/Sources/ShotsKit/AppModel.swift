import AppKit
import Foundation
import Observation

/// Everything the windows and the menu bar show, and every action they can take.
///
/// Views read properties straight off the model; `@Observable` re-renders exactly the views
/// that read a property when it changes. Views never touch the store or the CLI directly.
@MainActor
@Observable
public final class AppModel {
    // MARK: Setup

    public private(set) var config: ShotsConfig
    /// Why the app can't show anything (no index, no `shots` command). Nil when all is well.
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

    /// The message for the error alert. Set it to nil to dismiss.
    public var lastError: String?

    // MARK: Dependencies

    @ObservationIgnored private var cli: ShotsCLI?
    @ObservationIgnored private var store: ShotStore?
    @ObservationIgnored private var lastDataVersion: Int64?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    public init(cli: ShotsCLI? = ShotsCLI.locate(), config: ShotsConfig = .defaults, store: ShotStore? = nil) {
        self.cli = cli
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
            await self?.connect()
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

    /// Re-reads the config and everything shown. For a "Refresh" command.
    public func refresh() async {
        store = nil
        await connect()
    }

    /// Reads the current scope and search, plus counts, failed jobs and recent shots.
    public func reload() async {
        guard let store else { return }
        let scope = scope, search = searchText
        do {
            let shots = try await store.shots(in: scope, matching: search)
            let counts = try await store.counts()
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

    private func connect() async {
        if cli == nil { cli = ShotsCLI.locate() }
        var problems: [String] = []
        if let cli {
            do { config = try await cli.config() } catch { problems.append(error.localizedDescription) }
        } else {
            problems.append("The shots command isn't installed. Run scripts/install.sh, or set SHOTS_BIN.")
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
        // Without the CLI the app can still browse, so only a missing index blocks the window.
        setupError = store == nil ? problems.joined(separator: "\n") : nil
    }

    /// Reloads when the daemon (or a `recat`) has committed since the last look.
    private func poll() async {
        guard let store else {
            await connect() // The index may exist now, e.g. right after install.
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
    }

    // MARK: Changing shots (always through the CLI)

    /// Files the shot under `category` by hand. Also how a review is resolved.
    public func recategorize(_ shot: Shot, to category: String) async {
        guard category != shot.category || shot.needsReview else { return }
        await runRecat(on: shot) { cli in try await cli.recategorize(path: shot.path, to: category) }
    }

    /// Classifies the shot again with one backend.
    public func rerun(_ shot: Shot, backend: ClassifierBackend) async {
        await runRecat(on: shot) { cli in try await cli.rerun(path: shot.path, backend: backend) }
    }

    private func runRecat(on shot: Shot, _ command: (ShotsCLI) async throws -> RecatResult) async {
        guard let cli else {
            lastError = "The shots command isn't installed, so screenshots can't be changed."
            return
        }
        guard !recategorizing.contains(shot.id) else { return }
        recategorizing.insert(shot.id)
        defer { recategorizing.remove(shot.id) }

        do {
            let result = try await command(cli)
            // Show the new title/category/path right away; the reload below catches the rest.
            replace(result.shot)
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
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
