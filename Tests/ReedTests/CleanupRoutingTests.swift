import XCTest
@testable import Reed

/// Pins the rules-first AI-tier routing (2026-08-14): BasicCleanup runs
/// before the routing decision, so bare fillers and an open final sentence
/// never cost the ~1.5 s on-device model. Every test here stays on inputs the
/// rules resolve — nothing invokes the live Foundation Models session.
final class CleanupRoutingTests: XCTestCase {

    private var savedTier: String?

    override func setUp() {
        super.setUp()
        savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
    }

    override func tearDown() {
        if let savedTier {
            UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey)
        }
        super.tearDown()
    }

    // MARK: - BasicCleanup: bare "you know" is content, not a filler

    func testBareYouKnowIsPreserved() {
        // Stripping this changed meaning ("Do the answer?") — it's only a
        // filler in the comma-bounded aside form.
        XCTAssertEqual(
            BasicCleanup.clean("do you know the answer?"),
            "Do you know the answer?")
    }

    // MARK: - BasicCleanup: quoted fillers are mentioned, not spoken

    func testQuotedFillerSurvivesClean() {
        XCTAssertEqual(
            BasicCleanup.clean("as soon as I start saying \"um\" it slows down."),
            "As soon as I start saying \"um\" it slows down.")
        XCTAssertEqual(
            BasicCleanup.clean("the word “um” is a filler."),
            "The word “um” is a filler.")
    }

    func testUnquotedFillerStillStripped() {
        XCTAssertEqual(BasicCleanup.clean("um so we should go."), "So we should go.")
    }

    func testHasStrippableFiller() {
        XCTAssertTrue(BasicCleanup.hasStrippableFiller("Um, but now it works."))
        XCTAssertFalse(BasicCleanup.hasStrippableFiller("I keep saying \"um\" too much."))
        XCTAssertFalse(BasicCleanup.hasStrippableFiller("All clean here."))
    }

    // MARK: - BasicCleanup.close

    func testCloseAppendsPeriodToOpenTail() {
        XCTAssertEqual(BasicCleanup.close("ship it"), "ship it.")
    }

    func testCloseReplacesDanglingSeparator() {
        XCTAssertEqual(BasicCleanup.close("see you tomorrow,"), "see you tomorrow.")
        XCTAssertEqual(BasicCleanup.close("and then —"), "and then.")
    }

    func testCloseLeavesClosedTextAlone() {
        XCTAssertEqual(BasicCleanup.close("Done."), "Done.")
        XCTAssertEqual(BasicCleanup.close("Really?"), "Really?")
        XCTAssertEqual(BasicCleanup.close("He said \"go.\""), "He said \"go.\"")
        XCTAssertEqual(BasicCleanup.close(""), "")
    }

    // MARK: - needsAIReason

    // MARK: - Rules-first routing (no model call — rules resolve these)

    // The disfluency-signal gate ("fast path") was retired 2026-08-19:
    // checkbox on + model available = the model cleans every dictation.
    // applyWithPath on the .ai tier is exercised by hand and by the usage
    // log, not here — on a Mac with Apple Intelligence it would call the
    // live model, which has no place in a unit suite.

    func testBasicTierNeverCloses() async {
        // Parity: the basic tier is clean() only — closing belongs to the AI
        // tier's rules-first step.
        LocalCleanup.setTier(.basic)
        let result = await LocalCleanup.applyWithPath(to: "um send it over")
        XCTAssertEqual(result.text, "Send it over")
        XCTAssertEqual(result.path, .basic)
    }

    func testOffTierPassesThrough() async {
        LocalCleanup.setTier(.off)
        let result = await LocalCleanup.applyWithPath(to: "um raw text")
        XCTAssertEqual(result.text, "um raw text")
        XCTAssertEqual(result.path, .raw)
    }

    // MARK: - Structural disfluency detectors (run on the RAW transcript)

    func testStructuralDetectorsFireOnRealFailures() {
        // Every case here is a real dictation the lexical gate missed
        // (capture corpus, 2026-08-14).
        XCTAssertEqual(
            LocalCleanup.structuralReason("Okay, uh which is the uh uh open the show me the pull request link."),
            "doubled-filler")
        XCTAssertEqual(
            LocalCleanup.structuralReason("Okay, which is the open the show me the pull request link."),
            "det-restart")
        XCTAssertEqual(
            LocalCleanup.structuralReason("Also the the it looks like everything the quality dropped."),
            "doubled-word")
        XCTAssertEqual(
            LocalCleanup.structuralReason("and then uh and then once we merge it on the main."),
            "bigram-restart")
        XCTAssertEqual(
            LocalCleanup.structuralReason("clean things up s significantly better."),
            "stutter")
        XCTAssertEqual(
            LocalCleanup.structuralReason("being uh slow and um not doing the cleanup correctly."),
            "filler-dense")
        XCTAssertEqual(
            LocalCleanup.structuralReason("Or it's going to be a huge re re rework."),
            "doubled-word")
    }

    func testStructuralDetectorsStayQuietOnCleanSpeech() {
        for clean in [
            // Contractions are not stutters ("it's supposed", "it's how it's").
            "In general I like the order, it's how it's supposed to be, yes.",
            "now it's significantly worse.",
            // Repeated determiners in grammatical prose are fine.
            "At the end of the day the team decided to ship it.",
            "Do you know the answer?",
            "Hi Dana, thanks for sending over the report. I've reviewed it and it looks good.",
            "The invoice is £15.50 due on the 15th of March at 9.30 in the morning.",
            // Utterance- and sentence-initial fillers are cadence, not damage.
            "Um yes, that sounds good. Um do the fifty five version of it.",
        ] {
            XCTAssertNil(LocalCleanup.structuralReason(clean), clean)
        }
    }

    func testStructuralSignalSurvivesEvenWhenRulesWouldCleanIt() async {
        // The regression this guards: BasicCleanup strips the "uh"s, making
        // the rest look provably clean — the routing decision must happen on
        // the raw text. On a machine without the model this lands on .basic;
        // with it, .ai — either way it must NOT be .fast, and the trigger
        // must be the structural one.
        LocalCleanup.setTier(.ai)
        let raw = "We pay attention on c uh uh cloud mode."
        let structural = LocalCleanup.structuralReason(raw)
        XCTAssertEqual(structural, "doubled-filler")
        let rulesOnly = BasicCleanup.close(BasicCleanup.clean(raw))
        XCTAssertNil(LocalCleanup.needsAIReason(rulesOnly),
                     "rules output looks clean — exactly why raw must be consulted")
    }

}
