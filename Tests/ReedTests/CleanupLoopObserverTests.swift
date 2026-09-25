import XCTest
@testable import Reed

/// P16: the real per-chunk loop (`LocalCleanup.cleanLine`) reports each
/// chunk, each attempt and each outcome to the observer, with the model
/// stood in for by the seam. Needs the AI tier's availability check to
/// pass (macOS 26 with Apple Intelligence), so it skips on CI.
final class CleanupLoopObserverTests: XCTestCase {
    private var review: DictationReview!
    private var savedTier: String?

    override func setUpWithError() throws {
        guard #available(macOS 26.0, *), AICleanup.isAvailable else {
            throw XCTSkip("needs the on-device cleanup model's availability")
        }
        savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.ai)
        review = DictationReview(keepsContent: true)
    }

    override func tearDown() {
        LocalCleanup.modelCallOverrideForTests = nil
        if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
        else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
    }

    /// The loop under the binding the coordinator uses.
    private func clean(_ text: String) async -> LocalCleanup.Outcome {
        await LocalCleanup.$observer.withValue(review) {
            await LocalCleanup.$chunkSpan.withValue([0]) { await LocalCleanup.applyWithPath(to: text) }
        }
    }

    private func chunks() -> [ReviewRecord.Chunk] {
        review.finish(.init(injection: .init(text: "", target: nil, method: "ax"), timings: .init(totalSeconds: 0), mode: "", engine: "")).chunks
    }

    func testAnAcceptedChunkIsReportedAsModelAccepted() async throws {
        LocalCleanup.modelCallOverrideForTests = { text, _ in .text(text.replacingOccurrences(of: "um ", with: "")) }
        let outcome = await clean("so um the meeting is at noon.")
        XCTAssertEqual(outcome.path, .ai)
        let seen = chunks()
        XCTAssertEqual(seen.count, 1)
        let chunk = try XCTUnwrap(seen.first, "the accepted chunk was never reported")
        XCTAssertEqual(chunk.outcome, .modelAccepted)
        XCTAssertEqual(chunk.attempts.count, 1)
        XCTAssertEqual(chunk.delivered, outcome.text)
        XCTAssertEqual(review.counts.modelAccepted, 1)
    }

    func testARejectedProposalFallsToRulesAndIsReportedWithTheReason() async {
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text("the meeting is at noon tomorrow.") }  // adds a word
        let outcome = await clean("the meeting is at noon.")
        XCTAssertEqual(outcome.reason?.contains("gate-reject(added-word)"), true)
        let seen = chunks()
        XCTAssertEqual(seen.map(\.outcome), [.rulesAfterRejection])
        XCTAssertEqual(seen.first?.attempts.first?.gateRejection, "added-word")
        XCTAssertEqual(review.counts.rejections, ["added-word": 1])
    }

    func testAModelThatFailsIsReportedAsModelFailedWithItsClass() async throws {
        LocalCleanup.modelCallOverrideForTests = { _, _ in .failed("timeout 2.5s") }
        _ = await clean("the meeting is at noon.")
        let seen = chunks()
        XCTAssertEqual(seen.count, 1)
        let chunk = try XCTUnwrap(seen.first)
        XCTAssertNil(chunk.attempts.first?.proposal)
        XCTAssertEqual(chunk.outcome, .modelFailed, "no proposal: the attempt failed and rules carried the chunk")
        XCTAssertEqual(chunk.attempts.first?.verdict, "failed:timeout 2.5s")
        XCTAssertEqual(chunk.reason, "timeout 2.5s")
        XCTAssertEqual(review.counts.failures, ["timeout 2.5s": 1])
    }

    func testEveryChunkTheLoopMakesIsReported() async {
        LocalCleanup.modelCallOverrideForTests = { text, _ in .text(text) }
        // Two sentences too long for the chunker to coalesce into one call.
        let text = "The first sentence of this dictation runs on for quite a while before it finally reaches its end. "
            + "The second sentence of this dictation also runs on for quite a while before it reaches its own end."
        let expected = SentenceChunker.chunks(text, coalesce: true, glueFragments: true).count
        _ = await clean(text)
        XCTAssertEqual(chunks().count, expected, "one report per chunk the loop made")
        XCTAssertEqual(review.counts.chunks, expected)
        XCTAssertGreaterThanOrEqual(expected, 2)
    }

    /// Decision 2: a restart the model leaves as spoken is collapsed on the
    /// model path too, under the same licence.
    /// Review 2026-09-06 (P2): the collapse runs once on the model path too —
    /// three copies leave two after one pass, as in the rules pass.
    func testTheModelPathCollapsesOnceEvenWhenTheRulesPassRuns() async {
        LocalCleanup.modelCallOverrideForTests = { text, _ in .text(text) }
        let outcome = await clean("Um tell me tell me tell me what you think.")
        XCTAssertEqual(outcome.text, "Tell me tell me what you think.")
    }

    func testARestartTheModelLeftAloneIsCollapsedAfterAcceptance() async {
        LocalCleanup.modelCallOverrideForTests = { text, _ in .text(text) }
        let outcome = await clean("Tell me tell me what you think.")
        XCTAssertEqual(outcome.path, .ai)
        XCTAssertEqual(outcome.text, "Tell me what you think.")
    }
}
