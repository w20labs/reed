import XCTest
@testable import Reed

/// Natural self-correction across sentence marks and pause seams
/// (2026-10-14): what the model sees together, and which prompt it gets.
final class SelfCorrectionChunkingTests: XCTestCase {
    /// P01: the re-said sentence and the one it revises are one call, on
    /// their own — coalescing used to split them across two calls.
    func testARevisedSentenceIsCleanedWithTheOneItRevisesAndNothingElse() {
        let text = "Can you send this to the team? We were going to go. We are going to go. Please update the calendar."
        XCTAssertEqual(SentenceChunker.split(text, coalesce: true, glueFragments: true),
                       ["Can you send this to the team?", "We were going to go. We are going to go.", "Please update the calendar."])
    }

    /// U04: a short phrase that redoes the end of the sentence before it.
    func testAShortCompletionIsCleanedWithTheSentenceItCompletes() {
        XCTAssertEqual(SentenceChunker.split("I want to send this on Thursday. On Friday.", coalesce: false),
                       ["I want to send this on Thursday. On Friday."])
    }

    func testSentencesThatDoNotReviseStayApart() {
        for (previous, next) in [("Short one.", "Short two."), ("Call Sam.", "Call Priya too."),
                                 ("Do not do it.", "Do not do it now."), ("He said \"tell me.\"", "Tell me more."),
                                 ("We need more time.", "More."), ("We must test this.", "We must test this before release.")] {
            XCTAssertFalse(SentenceRevision.revises(previous: previous, next: next), "\(previous) | \(next)")
        }
        XCTAssertTrue(SentenceRevision.revises(previous: "We were going to go.", next: "We are going to go."))
    }

    /// A chunk holding a revision gets the repair prompt, like a restart.
    func testARevisionRoutesToTheRepairPrompt() {
        XCTAssertEqual(LocalCleanup.structuralReason("I want to send this on Thursday. On Friday."), "sentence-revision")
        XCTAssertEqual(LocalCleanup.structuralReason("I can approve I cannot approve the refund."), "subject-restart")
        XCTAssertEqual(LocalCleanup.structuralReason("I think we can we should postpone the launch."), "subject-restart")
        // The same subject and verb again is an idiom, not a restart.
        XCTAssertNil(StumbleDetector.restart("It is what it is, and the plan is the plan."))
        XCTAssertNil(LocalCleanup.structuralReason("Please send the draft to Sam and Priya."))
    }

    /// The pause-seam sibling: a revision split across a pause is re-cleaned
    /// as one piece, exactly like a cue ("…Bob. [pause] Wait, no, Alice.").
    @MainActor
    func testARevisionAcrossAPauseIsRecleanedTogether() async {
        let pieces = [Coordinator.Piece(text: "We were going to go.", sealedBy: .pause), .init(text: "We are going to go.", sealedBy: nil)]
        var decisions: [Int: ReviewRecord.JoinDecision] = [:]
        _ = await Coordinator.assembleSegments(pieces) { decisions[$0] = $1 }
        XCTAssertEqual(decisions, [1: .recleanedAcrossCue])
        let apart = [Coordinator.Piece(text: "We tested it on Monday.", sealedBy: .pause), .init(text: "Then we shipped it.", sealedBy: nil)]
        decisions = [:]
        _ = await Coordinator.assembleSegments(apart) { decisions[$0] = $1 }
        XCTAssertNotEqual(decisions[1], .recleanedAcrossCue)
    }
}
