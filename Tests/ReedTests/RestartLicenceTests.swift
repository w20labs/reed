import XCTest
@testable import Reed

/// Cleanup decision 2 (approved 2026-09-04): one restart rule, shared by the
/// gate, the rules pass and seam assembly. Strong phrase evidence only —
/// two to eight words re-spoken immediately; a single repeated word is
/// never collapsed by the deterministic passes; an "X and X and X" chain is
/// intentional.
final class RestartLicenceTests: XCTestCase {
    // MARK: - The deterministic collapse

    func testTheFieldRestartsCollapse() {
        for (input, expected) in [
            ("tell me tell me what you think", "tell me what you think"),
            ("I said something like something like this is fine", "I said something like this is fine"),
            ("I want to I want to go over the numbers first.", "I want to go over the numbers first."),
            ("So the plan the plan is to ship on Monday.", "So the plan is to ship on Monday."),
            ("Tell me, tell me what you think.", "Tell me what you think."),
            ("Tell me tell me what you think.", "Tell me what you think.")   // the capital moves onto the kept copy
        ] {
            XCTAssertEqual(RestartLicence.collapse(input), expected, input)
        }
    }

    func testIntentionalRepetitionSurvives() {
        for text in [
            "It was really really bad.",                 // emphasis: a single word
            "No no no, that's wrong.",
            "very very good",
            "again and again and again",                 // an X-and-X chain
            "one by one by one",
            "more and more and more people",
            "day after day after day",
            "the the meeting"                            // a single function word: the gate's business, not this pass's
        ] {
            XCTAssertEqual(RestartLicence.collapse(text), text, text)
        }
    }

    /// Review 2026-09-06 (P1): a deterministic collapse passes the gate's
    /// invariants like any proposal, and never crosses a sentence mark.
    func testASentenceBoundaryIsNotARestartAndTheGateGuardsEveryCollapse() {
        XCTAssertEqual(RestartLicence.collapse("Never share it. Never share it outside the team."),
                       "Never share it. Never share it outside the team.", "two sentences, and a negation the gate protects")
        XCTAssertEqual(RestartLicence.collapse("It's done. It's done now."), "It's done. It's done now.")
        XCTAssertEqual(RestartLicence.collapse("We should ship it we should ship it today"), "We should ship it today", "same modal count: allowed")
        XCTAssertEqual(RestartLicence.collapse("I do not I do not want it"), "I do not I do not want it",
                       "same sentence, but the collapse would drop a negation: only the gate refuses this one")
        XCTAssertTrue(RestartLicence.endsSentence("team.")); XCTAssertTrue(RestartLicence.endsSentence("really?\""))
        XCTAssertFalse(RestartLicence.endsSentence("team,"))
    }

    /// Review 2026-09-06 (P2, round 2): a phrase that is a shorter unit
    /// repeated is repetition, on every path — never a restart.
    func testLongerRepetitionsAreNotRestarts() {
        for text in ["really really really really", "Really really really really bad.",
                     "again and again and again and again and again", "no no no no no no",
                     "one by one by one by one"] {
            XCTAssertEqual(RestartLicence.collapse(text), text, text)
            XCTAssertEqual(BasicCleanup.clean(text).lowercased().replacingOccurrences(of: ".", with: ""), text.lowercased().replacingOccurrences(of: ".", with: ""), text)
        }
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "It was really really.", next: "Really really bad."))
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "again and again and.", next: "Again and again and again."))
        XCTAssertTrue(RestartLicence.isPeriodic(["really", "really"][...]))
        XCTAssertTrue(RestartLicence.isPeriodic(["again", "and", "again", "and"][...]))
        XCTAssertFalse(RestartLicence.isPeriodic(["tell", "me"][...]))
        XCTAssertFalse(RestartLicence.isPeriodic(["we", "need", "to"][...]))
    }

    /// Review 2026-09-06 (P2, round 2): only the pause's own mark may go —
    /// a seam match never reaches into an earlier sentence.
    func testASeamMatchNeverReachesPastThePausesOwnMark() {
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "I said yes. Tell me.", next: "Yes tell me more."))
        XCTAssertEqual(RestartLicence.crossSeamRestart(head: "I said. Tell me.", next: "Tell me more.")?.joined, "I said. Tell me more.",
                       "the mark inside the head is not in the abandoned copy")
    }

    /// Review 2026-09-06 (P2, round 2): paragraphs elsewhere survive a seam
    /// collapse, and a match never crosses one.
    func testParagraphsSurviveASeamCollapseAndAreNeverMatchedAcross() {
        let seam = RestartLicence.crossSeamRestart(head: "First line.\n\nHi my name is.", next: "My name is Aram.\n\nSecond line.")
        XCTAssertEqual(seam?.joined, "First line.\n\nHi my name is Aram.\n\nSecond line.")
        XCTAssertEqual(seam?.head, "First line.\n\nHi")
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "Hi my name is.\n\nOkay.", next: "My name is Aram."), "the abandoned copy is not on the head's last line")
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "Hi my name is.", next: "Okay.\n\nMy name is Aram."), "the copy is not on the next piece's first line")
    }

    /// Review 2026-09-06 (P2, round 3): the kept copy is one phrase too, and
    /// an opening quote or bracket travels with the phrase or blocks it.
    func testTheKeptCopyMustBeOnePhraseAndDelimitersSurvive() {
        XCTAssertEqual(RestartLicence.collapse("we need more time more. Time is running out."), "we need more time more. Time is running out.",
                       "the kept copy spans a sentence end")
        XCTAssertEqual(RestartLicence.collapse("tell me tell me. That is all."), "tell me. That is all.", "the kept copy may END the sentence")
        for (input, expected) in [
            ("He said \"tell me tell me what you think.\"", "He said \"tell me what you think.\""),
            ("He said “tell me tell me what you think.”", "He said “tell me what you think.”"),
            ("Note (tell me tell me what you think) later.", "Note (tell me what you think) later."),
            ("He said \"tell me\" tell me what you think.", "He said \"tell me\" tell me what you think."),   // a closer would go: declined
            ("Say 'go on go on' twice.", "Say 'go on' twice."),   // delimiters preserved: the closer stays on the kept copy
            // Round 4: a closer anywhere in the abandoned span, punctuation after it or not, declines.
            ("He said \"tell me\", tell me what you think.", "He said \"tell me\", tell me what you think."),
            ("He said \"go on\" and go on and finish it.", "He said \"go on\" and go on and finish it."),
            ("Note (tell me) tell me later.", "Note (tell me) tell me later."),
            ("Take [this one] this one too.", "Take [this one] this one too."),
            ("tell \"me tell me what you think", "tell \"me tell me what you think"),   // an opener inside the abandoned copy would be lost
            ("it's fine it's fine to go", "it's fine to go"),                             // an apostrophe inside a word is not a closer
            // Round 5: the kept copy opening a quotation is a quoted instruction, not a restart.
            ("Please say \"please say hello\" twice.", "Please say \"please say hello\" twice."),
            ("Type (type this) again.", "Type (type this) again."),
            ("He said \"she said 'she said hi' then\" and left.", "He said \"she said 'she said hi' then\" and left.")
        ] {
            XCTAssertEqual(RestartLicence.collapse(input), expected, input)
        }
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "We need more time.", next: "More. Time is running out."))
        XCTAssertEqual(RestartLicence.crossSeamRestart(head: "He said \"my name is.", next: "My name is Aram.\"")?.joined, "He said \"my name is Aram.\"")
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "He said \"my name is.\"", next: "My name is Aram."), "the closer would go with the abandoned copy")
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "He said \"go on\" and.", next: "Go on and finish it."), "a closer inside the abandoned span, at the seam")
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "Please say.", next: "\"Please say hello\" twice."), "the kept copy opens a quotation, at the seam")
        XCTAssertTrue(RestartLicence.endsWithCloser("me\","))
        XCTAssertTrue(RestartLicence.endsWithCloser("me)."))
        XCTAssertFalse(RestartLicence.endsWithCloser("don't"))
    }

    /// Review 2026-09-06 (P2): a chain needs a third copy — "go to go to" is a restart.
    func testAChainNeedsAThirdCopy() {
        XCTAssertEqual(RestartLicence.collapse("Please go to go to Settings."), "Please go to Settings.")
        XCTAssertEqual(RestartLicence.collapse("send it by send it by Friday"), "send it by Friday")
        XCTAssertEqual(RestartLicence.collapse("again and again and again"), "again and again and again")
        let tokens = "again and again and again".split(separator: " ").map(String.init)
        XCTAssertTrue(RestartLicence.isChain(at: 0, length: 2, tokens: tokens))
        XCTAssertFalse(RestartLicence.isChain(at: 0, length: 2, tokens: "go to go to settings".split(separator: " ").map(String.init)))
    }

    func testParagraphBreaksSurviveAndARestartNeverSpansOne() {
        XCTAssertEqual(RestartLicence.collapse("tell me tell me\n\nwhat you think"), "tell me\n\nwhat you think")
        XCTAssertEqual(RestartLicence.collapse("tell me\ntell me"), "tell me\ntell me", "the copies are on different lines: not a restart")
    }

    func testTheLongestPhraseWinsAndEightWordsIsTheCeiling() {
        XCTAssertEqual(RestartLicence.collapse("we need to we need to we need to go"), "we need to we need to go",
                       "one collapse per pass position: the first pair goes, the rest reads on")
        let nine = "a b c d e f g h i"
        XCTAssertEqual(RestartLicence.collapse("\(nine) \(nine) done"), "\(nine) \(nine) done", "nine words is not a restart")
        let eight = "a b c d e f g h"
        XCTAssertEqual(RestartLicence.collapse("\(eight) \(eight) done"), "\(eight) done")
    }

    // MARK: - Across a pause seam

    func testARestartSplitAcrossAPauseIsFound() {
        XCTAssertEqual(RestartLicence.crossSeamRestart(head: "Hi my name is.", next: "My name is Aram.")?.joined, "Hi my name is Aram.")
        XCTAssertEqual(RestartLicence.crossSeamRestart(head: "My name is.", next: "My name is Aram.")?.joined, "My name is Aram.", "the whole head was the abandoned start")
        XCTAssertEqual(RestartLicence.crossSeamRestart(head: "I said tell me,", next: "tell me what you think.")?.joined, "I said tell me what you think.")
    }

    /// Review 2026-09-06 (P2): the abandoned copy proves the casing.
    func testCasingAcrossTheSeamFollowsTheAbandonedCopy() {
        XCTAssertEqual(RestartLicence.crossSeamRestart(head: "Please ask Dana Connor.", next: "Dana Connor to join.")?.joined,
                       "Please ask Dana Connor to join.", "a proper name keeps its capital")
        XCTAssertEqual(RestartLicence.crossSeamRestart(head: "Okay. Tell me.", next: "Tell me what you think.")?.joined,
                       "Okay. Tell me what you think.", "the abandoned copy opened a sentence: so does the kept one")
        XCTAssertEqual(RestartLicence.crossSeamRestart(head: "So I think.", next: "I think we should go.")?.joined,
                       "So I think we should go.", "I keeps its case")
    }

    func testNoRestartAcrossAPauseForSingleWordsChainsDifferentPhrasesOrAGateRefusal() {
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "It was really.", next: "Really bad."), "a single word is emphasis")
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "No.", next: "No, not that."))
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "We went again and.", next: "Again and again."), "a chain")
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "Tell me.", next: "That intake is hard."))
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "We are going to.", next: "Spend the weekend."))
        XCTAssertNil(RestartLicence.crossSeamRestart(head: "Do not do it.", next: "Do not do it now."), "the gate: a negation would go")
    }

    // MARK: - The gate's rule is the same object

    func testTheGateStillLicensesItsRestartsThroughTheSharedRule() {
        let tokens = "ship it friday and tell them tell the team".split(separator: " ").map(String.init)
        XCTAssertTrue(RestartLicence.isRestart(4..<6, tokens: tokens), "tell them | tell the team")
        XCTAssertFalse(RestartLicence.isRestart(4..<5, tokens: tokens), "a single word is never a phrase")
        XCTAssertNil(CleanupGate.rejection(input: "Ship it Friday and tell them tell the team.", output: "Ship it Friday and tell the team.", repairHint: false))
        XCTAssertEqual(CleanupGate.rejection(input: "It was really really bad.", output: "It was really bad.", repairHint: true), .emphasisRepeat)
    }
}
