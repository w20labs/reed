import XCTest
@testable import Reed

/// The gate's side of natural self-correction (2026-10-14): which proposals
/// it accepts for each fixture, through `CleanupGate.rejection`, the same
/// call `LocalCleanup.modelAttempt` makes.
final class SelfCorrectionGateTests: XCTestCase {
    private func verdict(_ input: String, _ output: String, hint: Bool? = nil) -> CleanupGate.Rejection? {
        CleanupGate.rejection(input: input, output: output, repairHint: hint ?? (LocalCleanup.structuralReason(input) != nil))
    }

    /// Every intended repair's reference passes the gate, except U08, a
    /// bare number swap with no cue ("twelve, fifteen") that the gate
    /// cannot tell from a list — kept as spoken on purpose.
    func testEveryReferenceRepairIsAcceptedExceptAnUncuedNumberSwap() {
        for item in SelfCorrectionFixtures.research + SelfCorrectionFixtures.validation where item.kind == .repair {
            let rejection = verdict(item.text, item.expected)
            if item.id == "U08" {
                XCTAssertEqual(rejection, .unlicensedDeletion, item.id)
            } else {
                XCTAssertNil(rejection, "\(item.id): \(rejection?.rawValue ?? "")")
            }
        }
    }

    /// "Friday, sorry, not Friday, Monday": the "not" denies the abandoned
    /// option and goes with it (research M06; was refused as a lost "not").
    func testANegationThatDeniesTheAbandonedOptionMayGoWithIt() {
        XCTAssertNil(verdict("The deadline is Friday, sorry, not Friday, Monday.", "The deadline is Monday."))
        XCTAssertNil(verdict("The office is closed on Monday, sorry, not Monday, Tuesday.", "The office is closed on Tuesday."))
    }

    /// The same shapes without the licence still count every "not".
    func testANegationThatDeniesAnythingElseStillCounts() {
        // No cue: a plain contrast, not a correction.
        XCTAssertEqual(verdict("The deadline is Friday, not Monday.", "The deadline is Friday."), .negationChanged)
        // The "not" negates a word that was never offered before it.
        XCTAssertEqual(verdict("Ship it Friday, sorry, not Monday, Tuesday.", "Ship it Friday, Tuesday."), .negationChanged)
        // The negated option is deleted, but the "not" survives elsewhere wrongly: count unchanged rule.
        XCTAssertEqual(verdict("Do not delete the old backups until Maya approves.", "Delete the old backups until Maya approves."),
                       .negationChanged)
    }

    /// A marked correction resolved backwards keeps the abandoned option:
    /// refused mid-sentence too, not only at the end (validation V08 was
    /// accepted; research M03 reached the end and was already refused).
    func testKeepingTheAbandonedOptionIsRefusedMidSentence() {
        XCTAssertEqual(verdict("He has three, no wait, four kids.", "He has three kids."), .truncation)
        XCTAssertEqual(verdict("Send the report to Sam, I mean Priya.", "Send the report to Sam."), .truncation)
        XCTAssertEqual(verdict("Book the flight for Tuesday, I mean Wednesday, please.", "Book the flight for Tuesday, please."),
                       .truncation)
        // The right resolution of each still passes.
        XCTAssertNil(verdict("He has three, no wait, four kids.", "He has four kids."))
        XCTAssertNil(verdict("Book the flight for Tuesday, I mean Wednesday, please.", "Book the flight for Wednesday, please."))
    }

    /// A restart after a cue is a repair, and a cue with nothing kept before
    /// it abandons nothing: neither is a backwards resolution.
    func testARestartAfterACueIsNotAnAbandonedOption() {
        XCTAssertNil(verdict("No wait, we should, we should ship it today.", "No wait, we should ship it today."))
        XCTAssertNil(verdict("Actually, no, I cannot approve the refund.", "I cannot approve the refund."))
    }

    /// "had had" is the past perfect, not a stumble (research C10).
    func testHadHadIsGrammarNotAStumble() {
        XCTAssertEqual(verdict("We had had several discussions before deciding.", "We had several discussions before deciding."),
                       .emphasisRepeat)
        // Doubled function words and other auxiliaries still collapse.
        XCTAssertNil(verdict("I pushed the the fix and it is is working.", "I pushed the fix and it is working.", hint: true))
    }

    /// Every preservation fixture is accepted unchanged.
    func testEveryPreservationFixtureIsAcceptedAsSpoken() {
        for item in SelfCorrectionFixtures.research + SelfCorrectionFixtures.validation where item.kind == .preserve {
            XCTAssertNil(verdict(item.text, item.expected), item.id)
        }
    }

    /// A whole deleted sentence must be a revision the next sentence re-says
    /// (U01 accepted), never a contrast (C01) or an elaboration (C03).
    func testAWholeSentenceGoesOnlyWhenTheNextOneRevisesIt() {
        XCTAssertNil(verdict("We were going to go. We are going to go.", "We are going to go."))
        XCTAssertEqual(verdict("We were going to go yesterday. We are going to go tomorrow.", "We are going to go tomorrow."),
                       .unlicensedDeletion)
        XCTAssertEqual(verdict("We must test this. We must test this before release.", "We must test this before release."),
                       .unlicensedDeletion)
    }

    /// A completed contrast is not a restart (C02).
    func testAContrastIsNotARestart() {
        XCTAssertNotNil(verdict("We were going to go, but we are going to stay.", "We were going to stay."))
        // The contrast rule itself, apart from the final-version check that
        // also refuses this proposal.
        let keys = ["we", "were", "going", "to", "go", "but", "we", "are", "going", "to", "stay"]
        XCTAssertTrue(CleanupGate.losesContrast(2..<8, tokens: keys))
        XCTAssertFalse(CleanupGate.losesContrast(5..<7, tokens: keys), "a span opening with the conjunction is a restarted one")
        // A restarted conjunction still collapses.
        XCTAssertNil(verdict("But we, but we should ship it.", "But we should ship it.", hint: true))
    }

    /// A lone clause linker is not a stumble (V11).
    func testALoneLinkerStays() {
        XCTAssertEqual(verdict("I'll call you at noon, and I'll call him at one.", "I'll call you at noon. I'll call him at one."),
                       .unlicensedDeletion)
    }

    /// A modal replaced by a restart may go (V05); a proposal that leaves two
    /// modals side by side may not.
    func testAModalReplacedByARestartAndNoModalPileUp() {
        XCTAssertNil(verdict("We should we must finish the audit today.", "We must finish the audit today."))
        XCTAssertEqual(verdict("We should we must finish the audit today.", "We should must finish the audit today."),
                       .unlicensedDeletion)
        // Losing the only modal any other way still counts.
        XCTAssertEqual(verdict("We must finish the audit today.", "We finish the audit today."), .negationChanged)
    }
}
