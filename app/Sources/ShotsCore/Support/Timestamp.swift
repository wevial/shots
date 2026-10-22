import Foundation

/// The index stores times as JavaScript's `Date.toISOString()` writes them:
/// UTC with milliseconds, e.g. `2026-10-21T10:00:00.000Z`.
public enum Timestamp {
    public static func string(from date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    public static func now() -> String { string(from: .now) }

    /// Accepts both the millisecond form and plain `…T10:00:00Z`.
    public static func parse(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
