import ShotsCore

/// What `shots recat <path> --json` prints: the updated row plus how it was decided.
public struct RecatResult: Decodable, Sendable {
    public var shot: Shot
    public var decision: Decision

    public struct Decision: Decodable, Sendable {
        public var final: Classification
        public var backend: String
        public var review: Bool
        public var suggestedCategory: String?
    }

    public struct Classification: Decodable, Sendable {
        public var category: String
        public var tags: [String]
        public var title: String
        public var confidence: Double
    }
}

extension RecatResult {
    /// The same result from an in-process `recat`, without going through JSON.
    public init(_ output: RecatOutput) {
        let final = output.decision.final
        self.init(
            shot: Shot(row: output.shot),
            decision: Decision(
                final: Classification(category: final.category, tags: final.tags, title: final.title, confidence: final.confidence),
                backend: output.decision.backend,
                review: output.decision.review,
                suggestedCategory: output.decision.suggestedCategory
            )
        )
    }
}
