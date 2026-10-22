import Foundation

/// One backend's turn in the chain.
public struct Attempt: Sendable, Equatable, JSONRepresentable {
    public var backend: String
    public var ms: Int
    public var outcome: ClassifyOutcome

    public init(backend: String, ms: Int, outcome: ClassifyOutcome) {
        self.backend = backend
        self.ms = ms
        self.outcome = outcome
    }

    public var json: JSONValue { ["backend": .string(backend), "ms": JSONValue(ms), "outcome": outcome.json] }
}

/// What the chain settled on.
public struct ChainDecision: Sendable, Equatable, JSONRepresentable {
    /// What gets applied: the category is always one of the configured categories.
    public var final: ClassifyResult
    public var backend: String
    public var review: Bool
    /// The model's own category when the decision overrode it to misc.
    public var suggestedCategory: String?
    public var attempts: [Attempt]

    public init(final: ClassifyResult, backend: String, review: Bool, suggestedCategory: String?, attempts: [Attempt]) {
        self.final = final
        self.backend = backend
        self.review = review
        self.suggestedCategory = suggestedCategory
        self.attempts = attempts
    }

    /// `{final, backend, review, suggestedCategory, attempts}`, the `decision` half of
    /// `shots recat --json`.
    public var json: JSONValue {
        [
            "final": final.json, "backend": .string(backend), "review": .bool(review),
            "suggestedCategory": JSONValue(suggestedCategory), "attempts": .array(attempts.map(\.json)),
        ]
    }

    /// `attempts` as stored in `shots.attempts_json`.
    public var attemptsJSON: String { JSONValue.array(attempts.map(\.json)).serialized() }
}

/// Every backend failed (or none was configured). The file stays in the inbox.
public struct ChainError: LocalizedError, Sendable, Equatable {
    public var message: String
    public var attempts: [Attempt]
    public var errorDescription: String? { message }
}

/// Whether a shot may leave the machine.
public struct PrivacyVerdict: Sendable, Equatable {
    public var cloudAllowed: Bool
    /// Why not, for the log and the skipped attempts.
    public var reason: String?

    public init(cloudAllowed: Bool, reason: String?) {
        self.cloudAllowed = cloudAllowed
        self.reason = reason
    }

    public static let allowed = PrivacyVerdict(cloudAllowed: true, reason: nil)
}

public func privacyVerdict(_ config: Config, context ctx: AppContext?) -> PrivacyVerdict {
    if !config.allowCloud { return PrivacyVerdict(cloudAllowed: false, reason: "allowCloud=false") }
    let bundleId = ctx?.bundleId.flatMap { $0.isEmpty ? nil : $0 }
    let appName = ctx?.appName.flatMap { $0.isEmpty ? nil : $0 }
    if bundleId == nil, appName == nil {
        return config.cloudWhenAppUnknown ? .allowed : PrivacyVerdict(cloudAllowed: false, reason: "app unknown")
    }
    let deny = Set(config.cloudDenylist.map { $0.lowercased() })
    if let bundleId, deny.contains(bundleId.lowercased()) {
        return PrivacyVerdict(cloudAllowed: false, reason: "denylisted app \(bundleId)")
    }
    if let appName, deny.contains(appName.lowercased()) {
        return PrivacyVerdict(cloudAllowed: false, reason: "denylisted app \(appName)")
    }
    if let url = ctx?.url, let host = URL(string: url)?.host(percentEncoded: false)?.lowercased(), !host.isEmpty {
        let domains = config.cloudDenylistDomains.map { $0.lowercased().replacing(/^\*?\./, with: "") }
        if let hit = domains.first(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return PrivacyVerdict(cloudAllowed: false, reason: "denylisted domain \(hit)")
        }
    }
    return .allowed
}

/// Walks the backends in order. Stops at the first result at or above
/// `escalateBelowConfidence`; otherwise keeps the most confident result seen. When cloud is
/// off for this shot, `rules` is appended as a last resort so denylisted shots still get filed.
public func runChain(
    _ input: ClassifyInput,
    backends: [any Backend],
    config: Config,
    privacy: PrivacyVerdict,
    rules: (any Backend)? = nil
) async throws(ChainError) -> ChainDecision {
    var attempts: [Attempt] = []
    var ordered = backends
    if !privacy.cloudAllowed, let rules, !ordered.contains(where: { $0.name == rules.name }) { ordered.append(rules) }

    var best: (result: ClassifyResult, backend: String)?
    let clock = ContinuousClock()
    for backend in ordered {
        if backend.isCloud && !privacy.cloudAllowed {
            attempts.append(Attempt(backend: backend.name, ms: 0, outcome: .failure(.skipped, message: privacy.reason ?? "cloud disabled")))
            continue
        }
        let started = clock.now
        var outcome: ClassifyOutcome
        do {
            outcome = try await backend.classify(input)
        } catch {
            outcome = .failure(.error, message: errorMessage(error))
        }
        if case .success(var result, let detail) = outcome, let cap = config.confidenceCap[backend.name], result.confidence > cap {
            let note = "capped from \(JSONValue.formatNumber(result.confidence))"
            result.confidence = cap
            outcome = .success(result, detail: [detail, note].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", "))
        }
        attempts.append(Attempt(backend: backend.name, ms: Int((clock.now - started).milliseconds), outcome: outcome))
        guard let result = outcome.result else { continue }
        if best == nil || result.confidence > best!.result.confidence { best = (result, backend.name) }
        if result.confidence >= config.escalateBelowConfidence { break }
    }

    guard let best else {
        let summary = attempts.map { attempt in
            switch attempt.outcome {
            case .success: "\(attempt.backend): ok"
            case .failure(let kind, let message): "\(attempt.backend): \(kind.rawValue) (\(message))"
            }
        }.joined(separator: "; ")
        throw ChainError(message: "all backends failed: \(summary.isEmpty ? "no backends configured" : summary)", attempts: attempts)
    }
    return decide(best.result, backend: best.backend, config: config, attempts: attempts)
}

/// Applies the review rules: an unknown category or a confidence under
/// `reviewBelowConfidence` files the shot under misc and flags it for review.
public func decide(_ result: ClassifyResult, backend: String, config: Config, attempts: [Attempt] = []) -> ChainDecision {
    let known = config.categories.contains(result.category)
    let confident = result.confidence >= config.reviewBelowConfidence
    if known && confident {
        return ChainDecision(final: result, backend: backend, review: false, suggestedCategory: nil, attempts: attempts)
    }
    var parked = result
    parked.category = "misc"
    return ChainDecision(
        final: parked, backend: backend, review: true,
        suggestedCategory: result.category == "misc" ? nil : result.category, attempts: attempts
    )
}
