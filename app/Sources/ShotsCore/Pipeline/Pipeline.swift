import Foundation
import Synchronization

/// Everything a job needs. Built once per process; values and actors only, so it can be
/// shared by concurrent jobs.
public struct Deps: Sendable {
    public var config: Config
    public var database: Database
    public var native: any Native
    /// The configured chain, in order.
    public var backends: [any Backend]
    /// Local fallback used when cloud is off for a shot.
    public var rules: any Backend
    public var log: Logger
    public var stableOptions: Files.StableOptions

    public init(
        config: Config, database: Database, native: any Native, backends: [any Backend], rules: any Backend,
        log: Logger = Logger(), stableOptions: Files.StableOptions = Files.StableOptions()
    ) {
        self.config = config
        self.database = database
        self.native = native
        self.backends = backends
        self.rules = rules
        self.log = log
        self.stableOptions = stableOptions
    }

    /// The live setup: the configured backends plus the rules fallback.
    public init(config: Config, database: Database, native: any Native, log: Logger = Logger()) {
        self.init(
            config: config, database: database, native: native,
            backends: createBackends(config: config, native: native),
            rules: RulesBackend(appRules: config.appRules), log: log
        )
    }
}

public enum JobResult: Sendable, Equatable {
    case done(ShotRow)
    /// Not filed on purpose (duplicate, not a screenshot); the file stays in the inbox.
    case skipped(reason: String)
    /// The file stays in the inbox. `retry` is true while attempts remain and the file exists.
    case failed(error: String, retry: Bool)
}

public struct RecatOptions: Sendable {
    /// Use only these backends instead of the configured chain (`--backend`).
    public var backends: [any Backend]?
    /// Skip classification and file under this category (`--category`).
    public var category: String?

    public init(backends: [any Backend]? = nil, category: String? = nil) {
        self.backends = backends
        self.category = category
    }
}

/// What `recat` returns; its JSON is the `shots recat --json` contract the viewer decodes.
public struct RecatOutput: Sendable, Equatable, JSONRepresentable {
    public var shot: ShotRow
    public var decision: ChainDecision

    public init(shot: ShotRow, decision: ChainDecision) {
        self.shot = shot
        self.decision = decision
    }

    public var json: JSONValue { ["shot": shot.json, "decision": decision.json] }
}

/// The Finder tag shots adds to anything that needs a look.
public let reviewTag = "review"

/// Category, then the model's tags, then `review` when flagged; no duplicates.
public func finderTags(_ decision: ChainDecision) -> [String] {
    var seen = Set<String>()
    let tags = [decision.final.category] + decision.final.tags + (decision.review ? [reviewTag] : [])
    return tags.filter { seen.insert($0).inserted }
}

/// The app context stored on a shot, for re-classifying it. Nil when no app was recorded.
public func shotContext(_ shot: ShotRow) -> AppContext? {
    guard shot.appBundleId != nil || shot.appName != nil else { return nil }
    return AppContext(
        bundleId: shot.appBundleId, appName: shot.appName, windowTitle: shot.windowTitle, url: shot.url,
        urlTitle: shot.urlTitle, capturedAt: shot.capturedAt, accessibility: false, notes: []
    )
}

/// A job that ends as `skipped` rather than `failed`. Thrown inside `processJob` only.
private struct Skip: Error {
    var reason: String
    var sha256: String?
}

/// Runs one job from `pending` to `done`, `skipped` or `failed`. See src/pipeline.ts:
/// stable wait, sha256 dedupe (and skipped-sha memory), screenshot check, OCR, privacy
/// verdict, chain, row insert, then move (row deleted if the move fails), Finder tags and
/// clipboard (best effort). Never throws; failures leave the file in the inbox.
public func processJob(_ jobId: Int64, deps: Deps) async -> JobResult {
    let config = deps.config, db = deps.database, native = deps.native, log = deps.log

    let job: JobRow
    do {
        job = try await db.startJob(jobId)
    } catch {
        log.error("job could not start", ["job": JSONValue(jobId), "error": .string(errorMessage(error))])
        return .failed(error: errorMessage(error), retry: false)
    }
    let path = job.inboxPath

    do {
        try await Files.waitForStable(path, options: deps.stableOptions)
        let sha = try Files.sha256(path)
        if let duplicate = try await db.shot(bySha: sha) {
            throw Skip(reason: "duplicate of \(duplicate.path)", sha256: sha)
        }
        if let prior = try await db.skippedJob(forSha: sha, except: job.id) {
            throw Skip(reason: prior.lastError ?? "previously skipped", sha256: sha)
        }

        let meta = try await native.meta(path)
        if config.requireScreenCapture && meta.isScreenCapture != true {
            throw Skip(reason: "not a screen capture (metadata source: \(meta.source.rawValue))", sha256: sha)
        }
        // Copy now, not after filing: classifying can take 10 s and you want to paste right away.
        // Only for a screenshot that just landed (it has live context, first attempt), so a retry
        // or a startup scan never overwrites whatever you've copied since.
        if config.copyToClipboard && job.context != nil && job.attempts == 1 {
            await copyToClipboard(path, deps: deps)
        }

        let ocr = try await native.ocr(path, languages: config.ocrLanguages)
        let context = job.context
        let input = ClassifyInput(
            imagePath: path, ocrText: ocr.text, appContext: context, captureType: meta.captureType,
            dimensions: .init(width: ocr.width, height: ocr.height),
            categories: config.categories, categoryHints: config.categoryHints
        )
        let privacy = privacyVerdict(config, context: context)
        let decision = try await runChain(input, backends: deps.backends, config: config, privacy: privacy, rules: deps.rules)
        let captured = try Files.capturedAt(path)
        let dest = reserveDestination(
            in: Paths.join(config.outputRoot, decision.final.category),
            name: Files.targetName(captured: captured, title: decision.final.title, ext: Paths.extname(path))
        )
        defer { releaseDestination(dest) }

        // Row first, then move: a failed insert (e.g. a racing duplicate) leaves the file untouched.
        let shot = try await db.insertShot(NewShot(
            path: dest, originalName: Paths.basename(path), sha256: sha,
            capturedAt: Timestamp.string(from: captured), processedAt: Timestamp.now(),
            appBundleId: context?.bundleId, appName: context?.appName, windowTitle: context?.windowTitle,
            url: context?.url, urlTitle: context?.urlTitle, captureType: meta.captureType,
            width: ocr.width, height: ocr.height, ocrText: ocr.text,
            category: decision.final.category, suggestedCategory: decision.suggestedCategory,
            tags: decision.final.tags, title: decision.final.title, confidence: decision.final.confidence,
            backend: decision.backend, review: decision.review, attemptsJSON: decision.attemptsJSON
        ))
        do {
            try Files.safeMove(from: path, to: dest)
        } catch {
            try await db.deleteShot(shot.id)
            throw error
        }
        await applyTags(dest, tags: finderTags(decision), remove: [], deps: deps)
        try await db.finishJob(job.id, status: .done, sha256: sha, shotId: shot.id)

        var fields: JSONObject = [
            "from": .string(Paths.basename(path)), "to": .string(dest), "backend": .string(decision.backend),
            "confidence": .number(decision.final.confidence), "review": .bool(decision.review),
        ]
        if let reason = privacy.reason { fields["privacy"] = .string(reason) }
        fields["attempts"] = JSONValue(decision.attempts.map { attempt in
            switch attempt.outcome {
            case .success: "\(attempt.backend):ok"
            case .failure(let kind, _): "\(attempt.backend):\(kind.rawValue)"
            }
        })
        log.info("filed", fields)
        return .done(shot)
    } catch let skip as Skip {
        do {
            try await db.finishJob(job.id, status: .skipped, error: skip.reason, sha256: skip.sha256)
        } catch {
            return await fail(job, errorMessage(error), deps: deps)
        }
        log.info("skipped", ["path": .string(path), "reason": .string(skip.reason)])
        return .skipped(reason: skip.reason)
    } catch {
        return await fail(job, errorMessage(error), deps: deps)
    }
}

private func fail(_ job: JobRow, _ error: String, deps: Deps) async -> JobResult {
    let path = job.inboxPath
    do {
        try await deps.database.finishJob(job.id, status: .failed, error: error)
    } catch {
        deps.log.error("could not record job failure", ["job": JSONValue(job.id), "error": .string(errorMessage(error))])
    }
    let retry = job.attempts < deps.config.maxAttempts && FileManager.default.fileExists(atPath: path)
    deps.log.error("job failed; file left in inbox", [
        "path": .string(path), "error": .string(error), "attempt": JSONValue(job.attempts), "retry": .bool(retry),
    ])
    return .failed(error: error, retry: retry)
}

/// Destinations a job has picked but not moved its file into yet.
private let reservedDestinations = Mutex<Set<String>>([])

/// `Files.uniquePath`, also skipping names other jobs have reserved. Jobs run in parallel
/// and await the database between picking a name and moving the file, so two shots with
/// the same title in the same minute could otherwise both pick `name` and one move would fail.
private func reserveDestination(in dir: String, name: String, excluding exclude: String? = nil) -> String {
    let ext = Paths.extname(name)
    let stem = String(name.dropLast(ext.count))
    return reservedDestinations.withLock { reserved in
        var i = 1
        while true {
            let candidate = Paths.join(dir, i == 1 ? name : "\(stem)-\(i)\(ext)")
            if candidate == exclude || (!reserved.contains(candidate) && !FileManager.default.fileExists(atPath: candidate)) {
                reserved.insert(candidate)
                return candidate
            }
            i += 1
        }
    }
}

private func releaseDestination(_ path: String) {
    _ = reservedDestinations.withLock { $0.remove(path) }
}

/// Best-effort: the file is already filed and indexed.
private func applyTags(_ dest: String, tags: [String], remove: [String], deps: Deps) async {
    do {
        try await deps.native.setTags(dest, tags, remove: remove)
    } catch {
        deps.log.warn("finder tags failed", ["dest": .string(dest), "error": .string(errorMessage(error))])
    }
}

/// Best-effort. The pasteboard gets the image data, so moving the file afterwards is fine.
private func copyToClipboard(_ path: String, deps: Deps) async {
    do {
        try await deps.native.copyToClipboard(path)
    } catch {
        deps.log.warn("clipboard copy failed", ["path": .string(path), "error": .string(errorMessage(error))])
    }
}

/// Re-classifies an indexed shot from its stored OCR and context (or files it under
/// `options.category` by hand), then renames, moves and retags it. Throws when the file is
/// gone, the category is unknown, or an explicit cloud backend is blocked by privacy rules.
public func recat(_ shot: ShotRow, options: RecatOptions, deps: Deps) async throws -> RecatOutput {
    let config = deps.config
    guard FileManager.default.fileExists(atPath: shot.path) else { throw ShotsError("file is gone: \(shot.path)") }
    let context = shotContext(shot)
    // Everything shots may have tagged this file with before, so the retag replaces it.
    let oldTags = [shot.category] + shot.tags + [reviewTag]

    let decision: ChainDecision
    if let category = options.category {
        guard config.categories.contains(category) else {
            throw ShotsError("unknown category \"\(category)\" (have: \(config.categories.joined(separator: ", ")))")
        }
        decision = decide(
            ClassifyResult(category: category, tags: shot.tags, title: shot.title, confidence: 1),
            backend: "manual", config: config
        )
    } else {
        let privacy = privacyVerdict(config, context: context)
        // An explicit --backend that privacy rules forbid is an error, not a silent skip.
        let blocked = options.backends?.filter { $0.isCloud && !privacy.cloudAllowed } ?? []
        if !blocked.isEmpty {
            throw ShotsError("refusing to send to \(blocked.map(\.name).joined(separator: ", ")): \(privacy.reason ?? "cloud disabled")")
        }
        let dimensions: ClassifyInput.Dimensions? =
            if let width = shot.width, let height = shot.height, width != 0, height != 0 {
                .init(width: width, height: height)
            } else {
                nil
            }
        let input = ClassifyInput(
            imagePath: shot.path, ocrText: shot.ocrText, appContext: context, captureType: shot.captureType,
            dimensions: dimensions, categories: config.categories, categoryHints: config.categoryHints
        )
        decision = try await runChain(input, backends: options.backends ?? deps.backends, config: config, privacy: privacy, rules: deps.rules)
    }

    let captured = try shot.capturedDate ?? Files.capturedAt(shot.path)
    let dest = reserveDestination(
        in: Paths.join(config.outputRoot, decision.final.category),
        name: Files.targetName(captured: captured, title: decision.final.title, ext: Paths.extname(shot.path)),
        excluding: shot.path
    )
    defer { releaseDestination(dest) }
    try Files.safeMove(from: shot.path, to: dest)
    let updated = try await deps.database.updateShot(shot.id, ShotUpdate(
        path: dest, category: decision.final.category, suggestedCategory: decision.suggestedCategory,
        tags: decision.final.tags, title: decision.final.title, confidence: decision.final.confidence,
        backend: decision.backend, review: decision.review, attemptsJSON: decision.attemptsJSON
    ))
    await applyTags(dest, tags: finderTags(decision), remove: oldTags, deps: deps)
    return RecatOutput(shot: updated, decision: decision)
}
