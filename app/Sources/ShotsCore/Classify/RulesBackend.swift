import Foundation

/// Local, deterministic fallback: the app's bundle ID first, then OCR keywords. Never
/// leaves the machine; the denylist path uses it when Apple's model is unavailable.
public struct RulesBackend: Backend {
    public let name = "rules"
    public let isCloud = false
    public var appRules: [String: String]

    public init(appRules: [String: String]) {
        self.appRules = appRules
    }

    /// Category → pattern, tried in order. Ported from src/classify/rules.ts; the simple word
    /// boundary matches JavaScript's `\b`.
    private static let keywordRules: [(category: String, pattern: String)] = [
        ("errors", #"\b(traceback|exception|stack trace|segmentation fault|panic:|fatal error|errno|uncaught|TypeError|ReferenceError)\b"#),
        ("receipts", #"\b(receipt|order (number|#)|invoice|subtotal|amount paid|payment received)\b"#),
        ("finance", #"\b(balance|account (number|ending)|transactions?|statement|portfolio|routing)\b"#),
        ("travel", #"\b(boarding pass|flight|gate \w+|itinerary|check-in|reservation|departure)\b"#),
        ("code", #"(\bfunction\b|\bconst\b|\bimport\b|=>|\bdef\b|\breturn\b|\{\s*$|;\s*$)"#),
    ]

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? Regex(pattern) else { return false }
        return text.contains(regex.ignoresCase().wordBoundaryKind(.simple).anchorsMatchLineEndings())
    }

    public func classify(_ input: ClassifyInput) async -> ClassifyOutcome {
        let byApp = input.appContext?.bundleId.flatMap { appRules[$0] }
        let byKeyword = Self.keywordRules.first { input.categories.contains($0.category) && Self.matches($0.pattern, input.ocrText) }
        let category: String
        // An app mapping is a decent signal, keywords a weak one; misc means "no idea".
        let confidence: Double
        if let byApp, input.categories.contains(byApp) {
            (category, confidence) = (byApp, 0.7)
        } else if let byKeyword {
            (category, confidence) = (byKeyword.category, 0.5)
        } else {
            (category, confidence) = ("misc", 0.2)
        }
        var seen = Set<String>()
        let tags = [input.appContext?.appName, category]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .map(normalizeTag)
            .filter { seen.insert($0).inserted }
        return .success(ClassifyResult(
            category: category, tags: tags, title: Self.guessTitle(input), confidence: confidence,
            scratch: !input.scratchHints.isEmpty
        ))
    }

    private static func guessTitle(_ input: ClassifyInput) -> String {
        let ctx = input.appContext
        let firstLine = input.ocrText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.count >= 4 }
        let candidates = [ctx?.windowTitle, ctx?.urlTitle, firstLine, ctx?.appName]
        let raw = candidates.compactMap { $0?.isEmpty == false ? $0 : nil }.first ?? "screenshot"
        return raw.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
    }
}
