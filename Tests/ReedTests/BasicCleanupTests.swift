import XCTest
@testable import Reed

/// Pins the conservative Basic cleanup rules: fillers + casing only, never a
/// content rewrite. Guards against the tier ever altering meaning.
final class BasicCleanupTests: XCTestCase {
    func testRemovesLeadingAndMidFillers() {
        XCTAssertEqual(
            BasicCleanup.clean("um so i think uh we should go"),
            "So I think we should go")
    }

    func testCapitalizesSentences() {
        XCTAssertEqual(
            BasicCleanup.clean("hello world. how are you today"),
            "Hello world. How are you today")
    }

    func testDecimalPointIsNotASentenceEnd() {
        // Round-1 bench bugs: "9.30 In the morning" / "£15.50, Roughly $20".
        XCTAssertEqual(
            BasicCleanup.clean("due on the 15th of March at 9.30 in the morning"),
            "Due on the 15th of March at 9.30 in the morning")
        XCTAssertEqual(
            BasicCleanup.clean("around £15.50, roughly $20"),
            "Around £15.50, roughly $20")
    }

    func testDomainsSurviveSentenceCapitalization() {
        // Probe 2026-08-19: "example.com" was landing as "example.Com" — a
        // "." only ends a sentence when whitespace (or end of text) follows.
        XCTAssertEqual(
            BasicCleanup.clean("email jane at example.com now"),
            "Email jane at example.com now")
        XCTAssertEqual(
            BasicCleanup.clean("visit w20labs.ai today."),
            "Visit w20labs.ai today.")
    }

    func testDigitPeriodSpaceStillEndsSentence() {
        // "phase 2. next" IS a sentence break — only digit.digit is a decimal.
        XCTAssertEqual(
            BasicCleanup.clean("we start phase 2. next week works"),
            "We start phase 2. Next week works")
    }

    func testCommaBoundedLikeIsRemoved() {
        // ", like," is the filler form — removed whole, no comma debris.
        XCTAssertEqual(
            BasicCleanup.clean("maybe we should, uh, grab coffee and, like, catch up"),
            "Maybe we should grab coffee and catch up")
    }

    func testStandaloneIBecomesCapital() {
        XCTAssertEqual(BasicCleanup.clean("yesterday i left early"), "Yesterday I left early")
    }

    func testDoesNotTouchContentWords() {
        // "like" and "right" are real words — never stripped, even as verbal tics.
        let out = BasicCleanup.clean("i like it, right")
        XCTAssertTrue(out.contains("like"), out)
        XCTAssertTrue(out.contains("right"), out)
    }

    func testParagraphBreaksSurviveCleanup() {
        // Whitespace collapse must not cross newlines: `\s{2,}` flattened
        // "eggs\n\nmilk" into "eggs milk". Spaces/tabs collapse within a
        // line; \n and \n\n are preserved; spaces adjacent to newlines go.
        XCTAssertEqual(
            BasicCleanup.clean("eggs\n\nmilk and, um, bread"),
            "Eggs\n\nmilk and bread")
        XCTAssertEqual(BasicCleanup.clean("one  \n  two"), "One\ntwo")
    }

    func testNewlineBeforePunctuationSurvives() {
        // The space-before-punctuation rule must not eat a newline (backend
        // parity: `\s+([,.!?;:])` narrowed to `[ \t]+([,.!?;:])`).
        XCTAssertEqual(BasicCleanup.clean("first line\n\n. second"), "First line\n\n. Second")
    }

    func testRecapitalizesAfterExclamationAndQuestion() {
        // Parity fixture with the backend's rules_clean cleanup_gate set.
        XCTAssertEqual(
            BasicCleanup.clean("wow! that worked. amazing right"),
            "Wow! That worked. Amazing right")
        XCTAssertEqual(BasicCleanup.clean("really? yes it did"), "Really? Yes it did")
    }

    func testYouKnowPhraseRemoved() {
        // The comma-bounded pass removes the whole aside — no comma debris
        // (this used to pin the buggy "It was, really good").
        XCTAssertEqual(
            BasicCleanup.clean("it was, you know, really good"),
            "It was really good")
    }

    // MARK: - CleanupGate-protected tokens (review 2026-08-26)

    /// The gate guarantees formatter-built tokens survive the model
    /// byte-identical — and polish/clean then re-cased them two lines later.
    /// A sentence OPENING on a protected token must keep it verbatim.
    func testProtectedTokenOpeningASentenceIsNotRecased() {
        XCTAssertEqual(
            BasicCleanup.polish("jane@example.com is my address"),
            "jane@example.com is my address.")
        XCTAssertEqual(
            BasicCleanup.polish("x-1234 failed again"),
            "x-1234 failed again.")
        XCTAssertEqual(
            BasicCleanup.clean("example.com is down. check it"),
            "example.com is down. Check it")
    }

    /// The pronoun rule must not reach inside protected tokens…
    func testPronounRuleSkipsProtectedTokens() {
        XCTAssertEqual(
            BasicCleanup.clean("the case i-485 needs review"),
            "The case i-485 needs review")
    }

    /// …while the pronoun itself (bare and contracted) still uppercases.
    func testPronounStillCapitalizes() {
        XCTAssertEqual(BasicCleanup.clean("i think i'm ready"), "I think I'm ready")
    }

    /// Decision 2 (2026-09-04): the rules pass collapses a restart itself,
    /// under the licence the gate applies to the model.
    func testRestartsCollapseInTheRulesPass() {
        XCTAssertEqual(BasicCleanup.clean("tell me tell me what you think"), "Tell me what you think")
        XCTAssertEqual(BasicCleanup.clean("um tell me um tell me what you think"), "Tell me what you think", "fillers go first, then the restart")
        XCTAssertEqual(BasicCleanup.clean("it was really really bad"), "It was really really bad", "emphasis survives")
        XCTAssertEqual(BasicCleanup.clean("He said \"tell me tell me what you think.\""), "He said \"tell me what you think.\"", "the quote survives the rules pass")
        XCTAssertEqual(BasicCleanup.clean("He said \"tell me\", tell me what you think."), "He said \"tell me\", tell me what you think.", "a closer in the abandoned span: declined")
        XCTAssertEqual(BasicCleanup.clean("Please say \"please say hello\" twice."), "Please say \"please say hello\" twice.", "the kept copy opens a quotation: declined")
        XCTAssertEqual(BasicCleanup.clean("Never share it. Never share it outside the team."), "Never share it. Never share it outside the team.",
                       "two sentences, and the gate's negation rule, hold for the rules pass too")
    }
}
