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
