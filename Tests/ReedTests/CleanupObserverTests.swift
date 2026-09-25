import XCTest
@testable import Reed

/// P16: every model attempt reaches the observer with a typed verdict, and
/// the accept/reject decision the loop makes is the one it always made. The
/// model is stood in for by the test seam, so this runs on any Mac.
final class CleanupObserverTests: XCTestCase {
    private var review: DictationReview!

    override func setUp() {
        review = DictationReview(keepsContent: true)
    }

    override func tearDown() {
        LocalCleanup.modelCallOverrideForTests = nil
    }

    private func attempt(_ chunk: String, repair: Bool) async -> LocalCleanup.AttemptResult {
        await LocalCleanup.$observer.withValue(review) {
            await LocalCleanup.modelAttempt(chunk: chunk, repair: repair)
        }
    }

    private func attempts() -> [ReviewRecord.Attempt] {
        review.chunkDelivered("", outcome: .rulesOnly, reason: nil)
        let delivery = DictationReview.Delivery(injection: .init(text: "", target: nil, method: "ax"),
                                                timings: .init(totalSeconds: 0), mode: "", engine: "")
        return review.finish(delivery).chunks.first?.attempts ?? []
    }

    func testAnAcceptedProposalIsReportedAccepted() async {
        LocalCleanup.modelCallOverrideForTests = { text, _ in .text(text.replacingOccurrences(of: "um ", with: "")) }
        let result = await attempt("so um the meeting is at noon", repair: false)
        XCTAssertEqual(result.accepted, "so the meeting is at noon")
        XCTAssertEqual(result.verdict, .accepted)
        let seen = attempts()
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].kind, .generic)
        XCTAssertEqual(seen[0].proposal, "so the meeting is at noon")
        XCTAssertEqual(seen[0].verdict, "accepted")
        XCTAssertNil(seen[0].gateRejection)
        XCTAssertGreaterThanOrEqual(seen[0].seconds, 0)
    }

    func testARejectedProposalCarriesTheGatesReasonAndIsNotAccepted() async {
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text("the meeting is at noon tomorrow") }  // adds a word
        let result = await attempt("the meeting is at noon", repair: true)
        XCTAssertNil(result.accepted)
        XCTAssertEqual(result.gate, .addedWord)
        let seen = attempts()
        XCTAssertEqual(seen.map(\.kind), [.repair])
        XCTAssertEqual(seen[0].verdict, "gate:added-word")
        XCTAssertEqual(seen[0].gateRejection, "added-word")
        XCTAssertEqual(seen[0].proposal, "the meeting is at noon tomorrow", "the refused proposal is kept for review")
    }

    func testAFailedCallCarriesItsOwnFailureClass() async {
        LocalCleanup.modelCallOverrideForTests = { _, _ in .failed("timeout 2.5s") }
        let result = await attempt("anything at all", repair: false)
        XCTAssertNil(result.accepted)
        XCTAssertEqual(result.failure, "timeout 2.5s")
        let seen = attempts()
        XCTAssertEqual(seen[0].verdict, "failed:timeout 2.5s")
        XCTAssertNil(seen[0].proposal)
    }

    func testAnEmptyReplyIsTheEmptyFailure() async {
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text("") }
        let result = await attempt("anything at all", repair: false)
        XCTAssertEqual(result.failure, "empty")
    }

    /// Review 2026-09-05 (P2): head and tail segments are cleaned
    /// concurrently; a failure must belong to the call that had it, with
    /// nothing shared for the other call to overwrite or consume.
    func testConcurrentCallsKeepTheirOwnFailures() async {
        LocalCleanup.modelCallOverrideForTests = { text, _ in
            if text.hasPrefix("stalled") {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 0...3)))
                return .failed("timeout 2.5s")
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 0...3)))
            return .text(text)
        }
        for round in 0..<25 {
            async let stalled = LocalCleanup.modelAttempt(chunk: "stalled chunk \(round)", repair: false)
            async let fine = LocalCleanup.modelAttempt(chunk: "fine chunk \(round)", repair: false)
            let (first, second) = await (stalled, fine)
            XCTAssertEqual(first.failure, "timeout 2.5s", "round \(round)")
            XCTAssertEqual(second.verdict, .accepted, "round \(round)")
        }
    }

    func testAnUnfaithfulProposalIsItsOwnVerdictNotAGateReason() async {
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text("completely different words here entirely") }
        let result = await attempt("the meeting is at noon", repair: false)
        XCTAssertNil(result.accepted)
        XCTAssertEqual(result.verdict, .unfaithful)
        XCTAssertNil(result.gate, "the recall backstop refuses before the gate sees it")
        XCTAssertEqual(attempts()[0].verdict, "unfaithful")
    }

    func testNoObserverChangesNothing() async {
        LocalCleanup.modelCallOverrideForTests = { text, _ in .text(text) }
        let result = await LocalCleanup.modelAttempt(chunk: "hello there", repair: false)
        XCTAssertEqual(result.accepted, "hello there")
    }
}
