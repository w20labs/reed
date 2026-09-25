import XCTest
@testable import Reed

/// Repair-prompt trigger patterns (2026-08-29), anchored to the field
/// stumbles in docs/bench/repair_before.txt.
final class StumbleDetectorTests: XCTestCase {
    func testRestartsAreDetected() {
        XCTAssertEqual(StumbleDetector.restart("Ship it Friday and tell them tell the team."), "word-restart")
        XCTAssertEqual(StumbleDetector.restart("First can someone and Dana and Fel can someone add Dana and Felix."), "bigram-restart")
        // Known misses, deliberately: a function-word restart ("on her | on
        // the") and a content word two tokens apart ("ready on the ready")
        // look like ordinary prose lexically.
        XCTAssertNil(StumbleDetector.restart("Nadia reproduced it twice on her on the office Wi-Fi."))
    }

    func testNearCopiesAreDetected() {
        XCTAssertEqual(StumbleDetector.restart("Thanks and let me know if any of this does doesn't work for you."), "near-word")
        // "least latest" is three edits apart — a known miss.
        XCTAssertNil(StumbleDetector.restart("by the end of day at the least latest if review runs long"))
        // "One On" is a two-letter prefix — a known miss; "on one machine" must not trigger.
        XCTAssertNil(StumbleDetector.restart("One On the budget side, the invoice came in."))
        XCTAssertNil(StumbleDetector.restart("It happened on one machine, add Nadia and Toby to the invite."))
        XCTAssertNil(StumbleDetector.restart("as announced by the office of the chair on Wednesday"))
    }

    func testCleanProseDoesNotTrigger() {
        for text in [
            "The invoice total is $3,162, due on the 15th of March at 9:30 in the morning.",
            "Please schedule a meeting with the team at the Riverside office on Thursday afternoon.",
            "I think we should think about it before the review and then decide on the date.",
            "Send the report to Dana and the summary to Felix by the end of the day.",
            "It is what it is, and the plan is the plan."
        ] {
            XCTAssertNil(StumbleDetector.restart(text), text)
        }
    }

    func testStructuralReasonRoutesTheseToRepair() {
        XCTAssertEqual(LocalCleanup.structuralReason("Ship it Friday and tell them tell the team."), "word-restart")
        XCTAssertEqual(LocalCleanup.structuralReason("this does doesn't work"), "near-word")
        XCTAssertNil(LocalCleanup.structuralReason("Send the report to Dana by the end of the day."))
    }

    /// Review R4 (2026-08-30): prefix pairs on function words are prose.
    func testFunctionWordPrefixPairsDoNotTrigger() {
        for text in ["there are areas we should fix", "the theory behind it", "we can cancel the meeting",
                     "his history with the team", "for former employees", "he was washing the car",
                     "Dana and Android users"] {
            XCTAssertNil(StumbleDetector.restart(text), text)
        }
        XCTAssertEqual(StumbleDetector.restart("any of this does doesn't work"), "near-word")
        XCTAssertEqual(StumbleDetector.restart("but it is isn't ready"), "near-word")
    }
}

