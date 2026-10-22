/// Builds FTS5 queries the same way the daemon's `toFtsQuery` (src/db.ts) does, so the app
/// and `shots search` find the same things.
public enum FTSQuery {
    /// Each word becomes a quoted prefix term (`"tok"*`), so user input can't inject FTS syntax.
    /// Returns nil when there is nothing to search for.
    public static func build(_ input: String) -> String? {
        // Unicode-scalar semantics match JavaScript's /[\p{L}\p{N}_]+/gu (Swift's default is
        // per-grapheme, which would treat a letter plus a combining accent differently).
        let word = /[\p{L}\p{N}_]+/.matchingSemantics(.unicodeScalar)
        let terms = input.matches(of: word).map { "\"\($0.output)\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }
}
