import Testing
@testable import ShotsKit

struct FTSQueryTests {
    @Test func quotesEachWordAsAPrefixTerm() {
        #expect(FTSQuery.build("hello world") == #""hello"* "world"*"#)
    }

    @Test func dropsPunctuationAndFTSSyntax() {
        #expect(FTSQuery.build(#"foo-bar "baz" OR qux*"#) == #""foo"* "bar"* "baz"* "OR"* "qux"*"#)
    }

    @Test func keepsUnicodeLettersDigitsAndUnderscores() {
        #expect(FTSQuery.build("café 東京 snake_case 42") == #""café"* "東京"* "snake_case"* "42"*"#)
    }

    @Test(arguments: ["", "   ", "!?-*"])
    func emptyInputMeansNoSearch(_ input: String) {
        #expect(FTSQuery.build(input) == nil)
    }
}
