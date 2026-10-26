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
///
/// `onEvent` hears about live arrivals only (see `CaptureEvent`), synchronously and in order.
public func processJob(_ jobId: Int64, deps: Deps, onEvent: (CaptureEvent) -> Void = { _ in }) async -> JobResult {
    let config = deps.config, db = deps.database, native = deps.native, log = deps.log

    let job: JobRow
    do {
        job = try await db.startJob(jobId)
    } catch {
        log.error("job could not start", ["job": JSONValue(jobId), "error": .string(errorMessage(error))])
        return .failed(error: errorMessage(error), retry: false)
    }
    let path = job.inboxPath
    // A screenshot that just landed: it has live context and this is its first attempt.
    // Only these are copied and reported, so a retry or a startup scan never overwrites
    // whatever you've copied since, or pops up a preview for an old file.
    let isLiveArrival = job.context != nil && job.attempts == 1
    var reportedLanding = false

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
        if isLiveArrival {
            let copied = config.copyToClipboard ? await copyToClipboard(path, deps: deps) : false
            onEvent(.landed(jobID: job.id, path: path, copied: copied))
            reportedLanding = true
        }

        let ocr = try await native.ocr(path, languages: config.ocrLanguages)
        let context = job.context
        let input = ClassifyInput(
            imagePath: path, ocrText: ocr.text, appContext: context, captureType: meta.captureType,
            dimensions: .init(width: ocr.width, height: ocr.height),
            categories: config.categories, categoryHints: config.categoryHints,
            scratchHints: scratchHints(context, scratchApps: config.scratchApps)
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
            backend: decision.backend, review: decision.review, attemptsJSON: decision.attemptsJSON,
            scratch: decision.final.scratch
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
        if reportedLanding { onEvent(.filed(jobID: job.id, shot: shot)) }
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
        let result = await fail(job, errorMessage(error), deps: deps)
        if reportedLanding { onEvent(.failed(jobID: job.id, error: errorMessage(error))) }
        return result
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

/// Best-effort; true when it worked. The pasteboard gets the image data, so moving the file
/// afterwards is fine.
private func copyToClipboard(_ path: String, deps: Deps) async -> Bool {
    do {
        try await deps.native.copyToClipboard(path)
        return true
    } catch {
        deps.log.warn("clipboard copy failed", ["path": .string(path), "error": .string(errorMessage(error))])
        return false
    }
}

/// Catches the index up with a filed shot whose file was edited in place (cropped, rotated):
/// new hash, size and OCR text. Title, category and tags stay; nothing is moved or renamed.
/// Returns the updated row, or nil when the bytes haven't changed (or the file is gone).
@discardableResult
public func refreshContent(_ shot: ShotRow, deps: Deps) async throws -> ShotRow? {
    guard FileManager.default.fileExists(atPath: shot.path) else { return nil }
    // An editor may still be writing (Preview saves in several steps).
    try await Files.waitForStable(shot.path, options: deps.stableOptions)
    let sha = try Files.sha256(shot.path)
    guard sha != shot.sha256 else { return nil }
    let ocr = try await deps.native.ocr(shot.path, languages: deps.config.ocrLanguages)
    let updated = try await deps.database.updateShotContent(
        shot.id, sha256: sha, width: ocr.width, height: ocr.height, ocrText: ocr.text)
    deps.log.info("refreshed edited file", [
        "path": .string(shot.path), "width": JSONValue(ocr.width), "height": JSONValue(ocr.height),
    ])
    return updated
}

/// Moves a shot's file to the Trash and takes it out of the index. A shot whose file is
/// already gone just leaves the index. `moveToTrash` is for tests, which mustn't fill the real Trash.
public func trash(
    _ shot: ShotRow, deps: Deps,
    moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
) async throws {
    if FileManager.default.fileExists(atPath: shot.path) {
        try moveToTrash(URL(filePath: shot.path))
    }
    try await deps.database.removeShot(shot.id)
    deps.log.info("trashed", ["path": .string(shot.path)])
}

/// How long a shot stays in Recently Deleted before it goes to the Trash.
public let recentlyDeletedDays = 30

/// Where Recently Deleted keeps its files: hidden, and on the library's volume so moving in
/// and out is a rename.
public func deletedFolder(_ config: Config) -> String {
    Paths.join(config.outputRoot, ".deleted")
}

/// Puts a shot in Recently Deleted: its file moves to the hidden folder and the row is
/// flagged, so `restore` can put both back. A shot whose file is already gone is flagged as is.
public func softDelete(_ shot: ShotRow, deps: Deps) async throws -> ShotRow {
    guard shot.deletedAt == nil else { return shot }
    guard FileManager.default.fileExists(atPath: shot.path) else {
        return try await deps.database.markDeleted(shot.id, path: shot.path, from: shot.path)
    }
    let dest = reserveDestination(in: deletedFolder(deps.config), name: Paths.basename(shot.path))
    defer { releaseDestination(dest) }
    try Files.safeMove(from: shot.path, to: dest)
    do {
        let deleted = try await deps.database.markDeleted(shot.id, path: dest, from: shot.path)
        deps.log.info("deleted", ["path": .string(shot.path)])
        return deleted
    } catch {
        try? Files.safeMove(from: dest, to: shot.path)
        throw error
    }
}

/// Brings a shot back from Recently Deleted to where it was, under a new name if that one
/// was taken meanwhile.
public func restore(_ shot: ShotRow, deps: Deps) async throws -> ShotRow {
    guard shot.deletedAt != nil, let from = shot.deletedFrom else { return shot }
    guard FileManager.default.fileExists(atPath: shot.path), shot.path != from else {
        return try await deps.database.markRestored(shot.id, path: shot.path)
    }
    let dest = reserveDestination(in: Paths.dirname(from), name: Paths.basename(from))
    defer { releaseDestination(dest) }
    try Files.safeMove(from: shot.path, to: dest)
    do {
        let restored = try await deps.database.markRestored(shot.id, path: dest)
        deps.log.info("restored", ["path": .string(dest)])
        return restored
    } catch {
        try? Files.safeMove(from: dest, to: shot.path)
        throw error
    }
}

/// Sends whatever has been in Recently Deleted for `recentlyDeletedDays` to the Trash.
/// Returns how many went.
@discardableResult
public func sweepDeleted(
    now: Date = .now, deps: Deps,
    moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
) async throws -> Int {
    let cutoff = Timestamp.string(from: now.addingTimeInterval(-Double(recentlyDeletedDays) * 86_400))
    let expired = try await deps.database.deletedShots(before: cutoff)
    for shot in expired {
        try await trash(shot, deps: deps, moveToTrash: moveToTrash)
    }
    return expired.count
}

/// Copies a shot's file next to it as "<title> copy" and indexes the copy with everything the
/// original knows (text, context, tags), so the copy can be edited and the original kept.
public func duplicate(_ shot: ShotRow, deps: Deps) async throws -> ShotRow {
    guard FileManager.default.fileExists(atPath: shot.path) else { throw ShotsError("file is gone: \(shot.path)") }
    let title = "\(shot.title) copy"
    let captured = try shot.capturedDate ?? Files.capturedAt(shot.path)
    let dest = reserveDestination(
        in: Paths.dirname(shot.path),
        name: Files.targetName(captured: captured, title: title, ext: Paths.extname(shot.path))
    )
    defer { releaseDestination(dest) }

    // Row first, then copy, as when filing: a failed copy takes the row back out.
    let copy = try await deps.database.insertShot(NewShot(
        path: dest, originalName: shot.originalName, sha256: shot.sha256,
        capturedAt: shot.capturedAt, processedAt: Timestamp.now(),
        appBundleId: shot.appBundleId, appName: shot.appName, windowTitle: shot.windowTitle,
        url: shot.url, urlTitle: shot.urlTitle, captureType: shot.captureType,
        width: shot.width, height: shot.height, ocrText: shot.ocrText,
        category: shot.category, suggestedCategory: shot.suggestedCategory,
        tags: shot.tags, title: title, confidence: shot.confidence,
        backend: shot.backend, review: shot.review, attemptsJSON: shot.attemptsJSON
    ))
    do {
        // Keeps Finder tags and the screenshot markers, which are extended attributes.
        try FileManager.default.copyItem(atPath: shot.path, toPath: dest)
    } catch {
        try await deps.database.deleteShot(copy.id)
        throw error
    }
    deps.log.info("duplicated", ["from": .string(shot.path), "to": .string(dest)])
    return copy
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
            ClassifyResult(category: category, tags: shot.tags, title: shot.title, confidence: 1, scratch: shot.scratch ?? false),
            backend: "manual", config: config
        )
    } else {
        let privacy = privacyVerdict(config, context: context)
        // An explicit --backend that privacy rules forbid is an error, not a silent skip.
        let blocked = options.backends?.filter { $0.isCloud && !privacy.cloudAllowed } ?? []
        if !blocked.isEmpty {
            throw ShotsError("refusing to send to \(blocked.map(\.name).joined(separator: ", ")): \(privacy.reason ?? "cloud disabled")")
        }
        let input = classifyInput(for: shot, context: context, config: config)
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
        backend: decision.backend, review: decision.review, attemptsJSON: decision.attemptsJSON,
        // Filing by hand says nothing new about scratch; keep what the classifier said.
        scratch: options.category == nil ? decision.final.scratch : shot.scratch
    ))
    await applyTags(dest, tags: finderTags(decision), remove: oldTags, deps: deps)
    return RecatOutput(shot: updated, decision: decision)
}
