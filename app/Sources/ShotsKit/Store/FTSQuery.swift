import ShotsCore

/// Builds FTS5 queries the same way the daemon does (`toFtsQuery` in ShotsCore), so the app
/// and `shots search` find the same things.
public enum FTSQuery {
    /// Each word becomes a quoted prefix term (`"tok"*`), so user input can't inject FTS syntax.
    /// Returns nil when there is nothing to search for.
    public static func build(_ input: String) -> String? {
        let query = toFtsQuery(input)
        return query.isEmpty ? nil : query
    }
}
