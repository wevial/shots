import Foundation
import Synchronization
import Testing
@testable import ShotsCore

// Shared test helpers, ported from test/helpers.ts: a scripted backend, a fake `Native`,
// temp folders, and the PNG fixtures (regenerate with: swift Fixtures/make-fixtures.swift Fixtures).

enum Fixtures {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures").path

    static func path(_ name: String) -> String { Paths.join(directory, name) }

    /// Copies a fixture into `dir` under a screenshot-like name and returns its path.
    @discardableResult
    static func drop(_ fixture: String, into dir: String, as name: String) throws -> String {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = Paths.join(dir, name)
        try FileManager.default.copyItem(atPath: path(fixture), toPath: dest)
        return dest
    }
}

/// A fresh folder under the temp directory. The resolved path, so it compares equal to
/// what `Config` stores (`/var` is a symlink to `/private/var`).
func tempRoot() throws -> String {
    let url = URL.temporaryDirectory.appending(path: "shots-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath().path
}

/// Defaults rooted at `root`, with the inbox, output and data folders inside it.
func testConfig(_ root: String, _ overrides: JSONObject = [:]) throws -> Config {
    var user: JSONObject = [
        "inbox": .string(Paths.join(root, "inbox")),
        "outputRoot": .string(Paths.join(root, "out")),
        "dataDir": .string(Paths.join(root, "data")),
        "retryDelayMs": 50,
    ]
    for (key, value) in overrides { user[key] = value }
    return try Config.defaults(home: root).merging(user, home: root)
}

func testDeps(_ root: String, backends: [any Backend], native: any Native, _ overrides: JSONObject = [:]) throws -> Deps {
    let config = try testConfig(root, overrides)
    try FileManager.default.createDirectory(atPath: config.inbox, withIntermediateDirectories: true)
    return Deps(
        config: config,
        database: try Database(path: config.databasePath),
        native: native,
        backends: backends,
        rules: RulesBackend(appRules: config.appRules),
        log: .silent,
        stableOptions: Files.StableOptions(interval: .milliseconds(10), stableChecks: 2, timeout: .seconds(2))
    )
}

func appContext(
    bundleId: String? = "com.microsoft.VSCode", appName: String? = "Code", windowTitle: String? = "config.ts — shots",
    url: String? = nil, urlTitle: String? = nil
) -> AppContext {
    AppContext(bundleId: bundleId, appName: appName, windowTitle: windowTitle, url: url, urlTitle: urlTitle, accessibility: true)
}

func ok(_ category: String, _ confidence: Double, title: String? = nil, tags: [String]? = nil, scratch: Bool = false) -> ClassifyOutcome {
    .success(ClassifyResult(
        category: category, tags: tags ?? [category], title: title ?? "\(category) shot", confidence: confidence, scratch: scratch
    ))
}

func fail(_ kind: FailureKind, _ message: String? = nil) -> ClassifyOutcome {
    .failure(kind, message: message ?? kind.rawValue)
}

/// Polls `condition` until it holds, failing the test after `timeout`.
func until(timeout: Duration = .seconds(5), _ condition: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        if ContinuousClock.now > deadline { throw ShotsError("timed out waiting for condition") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A backend that replays scripted outcomes (the last one repeats) and records every input.
final class MockBackend: Backend {
    typealias Step = @Sendable (ClassifyInput) throws -> ClassifyOutcome

    let name: String
    let isCloud: Bool
    private let script: [Step]
    private let delay: Duration?
    private let state = Mutex(State())

    private struct State {
        var calls: [ClassifyInput] = []
        var active = 0
        var maxActive = 0
    }

    init(_ name: String, _ outcomes: [ClassifyOutcome], cloud: Bool = false, delay: Duration? = nil) {
        self.name = name
        self.isCloud = cloud
        self.script = outcomes.map { outcome in { _ in outcome } }
        self.delay = delay
    }

    init(_ name: String, cloud: Bool = false, steps: [Step]) {
        self.name = name
        self.isCloud = cloud
        self.script = steps
        self.delay = nil
    }

    var calls: [ClassifyInput] { state.withLock { $0.calls } }
    var maxActive: Int { state.withLock { $0.maxActive } }

    func classify(_ input: ClassifyInput) async throws -> ClassifyOutcome {
        let n = state.withLock { s in
            s.calls.append(input)
            s.active += 1
            s.maxActive = max(s.maxActive, s.active)
            return s.calls.count
        }
        defer { state.withLock { $0.active -= 1 } }
        if let delay { try await Task.sleep(for: delay) }
        return try script[min(n - 1, script.count - 1)](input)
    }
}

/// A `Native` with canned answers that records tags and clipboard writes.
final class FakeNative: Native {
    struct State {
        var tags: [String: [String]] = [:]
        var clipboard: [String] = []
        var contextCalls = 0
    }

    let context: AppContext?
    let isScreenCapture: Bool?
    let ocrText: String
    let ocrFails: Bool
    let fmResponse: FmClassifyResponse
    private let state = Mutex(State())

    /// - Parameter isScreenCapture: nil means the file has no screenshot metadata.
    init(
        context: AppContext? = appContext(), isScreenCapture: Bool? = true, ocrText: String = "hello world from a screenshot",
        ocrFails: Bool = false, fmResponse: FmClassifyResponse = .unavailable(reason: "test")
    ) {
        self.context = context
        self.isScreenCapture = isScreenCapture
        self.ocrText = ocrText
        self.ocrFails = ocrFails
        self.fmResponse = fmResponse
    }

    var tags: [String: [String]] { state.withLock { $0.tags } }
    var clipboard: [String] { state.withLock { $0.clipboard } }
    var contextCalls: Int { state.withLock { $0.contextCalls } }

    func meta(_ path: String) async throws -> ScreenshotMeta {
        ScreenshotMeta(
            isScreenCapture: isScreenCapture, captureType: isScreenCapture == true ? "selection" : nil,
            source: isScreenCapture == nil ? .none : .xattr
        )
    }

    func context() async throws -> AppContext? {
        state.withLock { $0.contextCalls += 1 }
        return context
    }

    func ocr(_ path: String, languages: [String]) async throws -> OcrResult {
        if ocrFails { throw ShotsError("ocr exploded") }
        return OcrResult(text: ocrText, width: 800, height: 600)
    }

    func fmStatus() async throws -> FmStatus {
        FmStatus(osVersion: "26.0.0", available: true, imageInput: .init(enabled: false, reason: "test"))
    }

    func fmClassify(instructions: String, prompt: String, imagePath: String, timeout: Duration) async -> FmClassifyResponse {
        fmResponse
    }

    func setTags(_ path: String, _ tags: [String], remove: [String]) async throws {
        state.withLock { s in
            var merged = (s.tags[path] ?? []).filter { !remove.contains($0) }
            for tag in tags where !merged.contains(tag) { merged.append(tag) }
            s.tags[path] = merged
        }
    }

    func copyToClipboard(_ path: String) async throws {
        state.withLock { $0.clipboard.append(path) }
    }

    func permissions() async throws -> Permissions {
        Permissions(accessibility: true, screenRecording: false)
    }
}

/// Collects `CaptureEvent`s from any thread, for `processJob(onEvent:)` and `Daemon(onCapture:)`.
final class EventRecorder: Sendable {
    private let recorded = Mutex<[CaptureEvent]>([])

    var events: [CaptureEvent] { recorded.withLock { $0 } }

    func record(_ event: CaptureEvent) {
        recorded.withLock { $0.append(event) }
    }
}
