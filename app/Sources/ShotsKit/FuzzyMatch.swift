import Foundation

/// Fuzzy matching for the command palette: the query's letters must appear in the title in
/// order, but not necessarily next to each other ("rvf" finds "Reveal in Finder").
///
/// Matches score higher when they start words, run together, or start the title, so typing
/// the first letters of words finds the command you mean.
public enum FuzzyMatch {
    static let matchScore = 1
    static let wordStartBonus = 8
    static let prefixBonus = 6
    static let consecutiveBonus = 4
    static let gapPenalty = 1

    /// How well `query` matches `title`, or nil when it doesn't. Ignores case and accents; spaces in
    /// the query are ignored. An empty query matches everything with a score of 0.
    public static func score(_ query: String, in title: String) -> Int? {
        let query = query.filter { !$0.isWhitespace }.map(folded)
        let title = Array(title)
        let lowered = title.map(folded)
        guard !query.isEmpty else { return 0 }
        guard query.count <= title.count else { return nil }

        // The same letter can appear several times in a title, and the first occurrence isn't
        // always the best one ("fi" in "Refresh Finder" should use the F of Finder). So for each
        // query letter, `best[j]` keeps the best score of any match that puts that letter at
        // title position j, built from the previous letter's scores.
        var best = [Int?](repeating: nil, count: title.count)
        for (j, character) in lowered.enumerated() where character == query[0] {
            best[j] = letterScore(at: j, in: title) + (j == 0 ? prefixBonus : 0)
        }

        for letter in query.dropFirst() {
            var next = [Int?](repeating: nil, count: title.count)
            for (j, character) in lowered.enumerated() where character == letter {
                var bestBefore: Int?
                for k in 0..<j {
                    guard let previous = best[k] else { continue }
                    let gap = j - k - 1
                    let joined = previous + (gap == 0 ? consecutiveBonus : -gap * gapPenalty)
                    bestBefore = max(bestBefore ?? joined, joined)
                }
                if let bestBefore { next[j] = bestBefore + letterScore(at: j, in: title) }
            }
            best = next
        }
        return best.compactMap(\.self).max()
    }

    /// The items whose title matches `query`, best first. Equal scores keep their input order,
    /// so an empty query returns `items` unchanged.
    public static func filter<Item>(_ items: [Item], query: String, title: (Item) -> String) -> [(item: Item, score: Int)] {
        items.enumerated()
            .compactMap { index, item in score(query, in: title(item)).map { (index, item, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map { (item: $0.1, score: $0.2) }
    }

    /// Lowercased and without accents, so "cafe" finds "Café". A String, not a Character,
    /// because a few characters fold to more than one.
    private static func folded(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func letterScore(at index: Int, in title: [Character]) -> Int {
        matchScore + (isWordStart(index, in: title) ? wordStartBonus : 0)
    }

    /// The first letter of the title or of a word ("Re-run", "Move to code", "QuickLook").
    private static func isWordStart(_ index: Int, in title: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = title[index - 1], current = title[index]
        if !(previous.isLetter || previous.isNumber) { return true }
        return previous.isLowercase && current.isUppercase
    }
}
