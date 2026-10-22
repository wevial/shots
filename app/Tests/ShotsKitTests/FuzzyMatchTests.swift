import Testing
@testable import ShotsKit

struct FuzzyMatchTests {
    @Test func matchesLettersInOrderIgnoringCase() {
        #expect(FuzzyMatch.score("rvf", in: "Reveal in Finder") != nil)
        #expect(FuzzyMatch.score("REVEAL", in: "Reveal in Finder") != nil)
        #expect(FuzzyMatch.score("dv", in: "Reveal in Finder") == nil) // Out of order.
        #expect(FuzzyMatch.score("x", in: "Reveal in Finder") == nil)
    }

    @Test func ignoresSpacesInTheQuery() {
        #expect(FuzzyMatch.score("move code", in: "Move to code") != nil)
        #expect(FuzzyMatch.score("   ", in: "Anything") == 0)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatch.score("", in: "Refresh") == 0)
        #expect(FuzzyMatch.score("", in: "") == 0)
    }

    @Test func prefixBeatsAMatchLaterInTheTitle() throws {
        let prefix = try #require(FuzzyMatch.score("co", in: "Copy Path"))
        let later = try #require(FuzzyMatch.score("co", in: "Go to code"))
        #expect(prefix > later)
    }

    @Test func wordStartsBeatLettersInsideWords() throws {
        let wordStarts = try #require(FuzzyMatch.score("ql", in: "Quick Look"))
        let inside = try #require(FuzzyMatch.score("ql", in: "Squeal"))
        #expect(wordStarts > inside)
    }

    @Test func picksTheBestOccurrenceOfARepeatedLetter() throws {
        // A greedy match would take the f inside "Refresh"; the F of "Finder" scores higher.
        let score = try #require(FuzzyMatch.score("fi", in: "Refresh Finder"))
        let direct = try #require(FuzzyMatch.score("fi", in: "Finder"))
        #expect(score == direct - FuzzyMatch.prefixBonus)
    }

    @Test func consecutiveLettersBeatScatteredOnes() throws {
        let together = try #require(FuzzyMatch.score("open", in: "Open Inbox Folder"))
        let scattered = try #require(FuzzyMatch.score("open", in: "Bootstrap Queen"))
        #expect(together > scattered)
    }

    @Test func filterRanksBestFirstAndKeepsOrderOnTies() {
        let titles = ["Go to code", "Copy Path", "Copy Image", "Refresh"]
        #expect(FuzzyMatch.filter(titles, query: "co", title: { $0 }).map(\.item) == ["Copy Path", "Copy Image", "Go to code"])
        #expect(FuzzyMatch.filter(titles, query: "", title: { $0 }).map(\.item) == titles)
    }

    @Test func ignoresAccents() {
        #expect(FuzzyMatch.score("cafe", in: "Café receipt") != nil)
        // "İ" lowercases to two scalars, "i" plus a combining dot.
        #expect(FuzzyMatch.score("istanbul", in: "İstanbul trip") != nil)
    }
}
