import XCTest
@testable import Reed

/// The model-free half of cap-boundary assembly (latency step 2, 2026-08-28).
final class OverlapAssemblyTests: XCTestCase {
    func testTrimOverlapDropsTheWordsThePreRollRepeated() {
        let seam = Coordinator.trimOverlap(head: "and the demo video ready to go instead of the.", next: "of the blog post and the demo")
        XCTAssertEqual(seam.removed, 2)
        XCTAssertEqual(seam.head, "and the demo video ready to go instead of the.")
        XCTAssertEqual(seam.next, "blog post and the demo")
    }

    func testTrimOverlapIsCaseAndPunctuationInsensitive() {
        let seam = Coordinator.trimOverlap(head: "add the tool.", next: "Tool tip that Dana asked for.")
        XCTAssertEqual(seam.removed, 1)
        XCTAssertEqual(seam.head, "add the tool.")
        XCTAssertEqual(seam.next, "tip that Dana asked for.")
    }

    /// The head's duplicate is kept once — on the head side; the next
    /// segment's copy goes. The words the recognizer hallucinated around it
    /// go too: a phrase completion at the head's truncated end, a mis-heard
    /// short word at the next's start (run-on bench 2026-08-28).
    func testTrimOverlapDropsJunkAroundTheDuplicate() {
        // "…we're going to start | going to spend…"
        let seam = Coordinator.trimOverlap(head: "And if we ship on Friday we're going to start.", next: "going to spend the whole weekend")
        XCTAssertEqual(seam.removed, 3)
        XCTAssertEqual(seam.head, "And if we ship on Friday we're going to", "junk dropped, the duplicate kept once")
        XCTAssertEqual(seam.next, "spend the whole weekend")
        // "…announce it | to it properly…"
        let seam2 = Coordinator.trimOverlap(head: "Then we announce it", next: "to it properly with the blog post")
        XCTAssertEqual(seam2.removed, 2)
        XCTAssertEqual(seam2.head, "Then we announce it")
        XCTAssertEqual(seam2.next, "properly with the blog post")
    }

    /// Parakeet completes a truncated phrase (finding 2, 2026-08-29): three
    /// invented words before a two-word duplicate still trim.
    func testTrimOverlapDropsAThreeWordCompletionBeforeATwoWordDuplicate() {
        let seam = Coordinator.trimOverlap(head: "And if we ship on Friday we are going to be able to", next: "going to spend the whole weekend")
        XCTAssertEqual(seam.removed, 5)
        XCTAssertEqual(seam.head, "And if we ship on Friday we are going to")
        XCTAssertEqual(seam.next, "spend the whole weekend")
    }

    /// A lone common word behind two junk words is not a duplicate — the
    /// first version trimmed "Date because the" here.
    func testTrimOverlapLeavesUnrelatedTextAlone() {
        let seam = Coordinator.trimOverlap(head: "we should move the.", next: "Date because the onboarding")
        XCTAssertEqual(seam.removed, 0)
        XCTAssertEqual(seam.next, "Date because the onboarding")
    }

    func testTrimOverlapPrefersTheLongestMatch() {
        let seam = Coordinator.trimOverlap(head: "one two three", next: "two three four")
        XCTAssertEqual(seam.removed, 2)
        XCTAssertEqual(seam.head, "one two three")
        XCTAssertEqual(seam.next, "four")
    }

    func testTrimOverlapNeverMatchesEmptyTokens() {
        let seam = Coordinator.trimOverlap(head: "wait —", next: "— go on")
        XCTAssertEqual(seam.removed, 0)
    }

    @MainActor
    func testSessionRemembersWhyEachSegmentSealed() async {
        let session = OverlapSession()
        session.arm()
        session.enqueue(sealedBy: .pause) { "a" }
        session.enqueue(sealedBy: .cap) { "b" }
        session.enqueue { "c" }
        XCTAssertEqual(session.boundaries, [.pause, .cap, .pause])
        _ = await session.collect()
        session.reset()
        XCTAssertTrue(session.boundaries.isEmpty)
    }

    func testJoinAcrossCutDropsTheBreakAndLowersTheOpeningCapital() {
        XCTAssertEqual(Coordinator.joinAcrossCut("we announce it properly with the.", "Blog post and the demo.", lowercaseFirst: true),
                       "we announce it properly with the blog post and the demo.")
        XCTAssertEqual(Coordinator.joinAcrossCut("and the tool.", "tip that Dana asked for.", lowercaseFirst: false),
                       "and the tool tip that Dana asked for.")
        XCTAssertEqual(Coordinator.joinAcrossCut("I think.", "I'll go.", lowercaseFirst: true), "I think I'll go.")
    }

    /// A pause seal on a breath: the head ends in a non-final word, so the
    /// pieces are one sentence (field 2026-08-29: "going to… | Spend").
    @MainActor
    func testPauseSealAfterANonFinalWordIsJoined() async {
        let pieces = [
            Coordinator.Piece(text: "If we ship on Friday, we are going to...", sealedBy: .pause),
            Coordinator.Piece(text: "Spend the whole weekend answering emails.", sealedBy: .pause),
            Coordinator.Piece(text: "Add Nadia to the.", sealedBy: .pause),
            Coordinator.Piece(text: "Invite and attach the mockups.", sealedBy: nil)
        ]
        let text = await Coordinator.assembleSegments(pieces)
        XCTAssertEqual(text, "If we ship on Friday, we are going to spend the whole weekend answering emails. Add Nadia to the invite and attach the mockups.")
    }

    @MainActor
    func testPauseSealAfterARealSentenceEndStaysABoundary() async {
        let pieces = [
            Coordinator.Piece(text: "Thanks for the report.", sealedBy: .pause),
            Coordinator.Piece(text: "Let's discuss it tomorrow.", sealedBy: nil)
        ]
        let text = await Coordinator.assembleSegments(pieces)
        XCTAssertEqual(text, "Thanks for the report. Let's discuss it tomorrow.")
    }
}

