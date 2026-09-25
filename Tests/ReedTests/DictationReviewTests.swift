import XCTest
@testable import Reed

/// P16: the per-dictation collector — segments, chunks attributed through
/// the task-local span, seams, delivery — and the content-free counts,
/// which are real with or without content.
final class DictationReviewTests: XCTestCase {
    private func drive(_ review: DictationReview) async {
        review.segment(0, boundary: .pause, raw: "hi my name is", corrected: "hi my name is", audioMs: 900, asrMs: 120)
        review.segment(1, boundary: .tail, raw: "my name is aram", corrected: "my name is Aram", audioMs: 1100, asrMs: 140)
        // Segment 1's chunk, then segment 0's — interleaved as concurrent
        // workers would, attributed by the task-local span.
        await LocalCleanup.$chunkSpan.withValue([1]) {
            review.chunkStarted(input: "my name is Aram", repairHint: "phrase-restart")
            review.attempt(.init(kind: .repair, proposal: "name is Aram", verdict: "gate:truncation", seconds: 0.4))
            review.attempt(.init(kind: .generic, proposal: "My name is Aram.", verdict: "accepted", seconds: 0.3))
            review.chunkDelivered("My name is Aram.", outcome: .modelAccepted, reason: nil)
        }
        await LocalCleanup.$chunkSpan.withValue([0]) {
            review.chunkStarted(input: "hi my name is", repairHint: nil)
            review.attempt(.init(kind: .generic, proposal: nil, verdict: "failed:timeout 8.0s", seconds: 8.0))
            review.chunkDelivered("Hi my name is.", outcome: .modelFailed, reason: "timeout 8.0s")
        }
        review.cleanupOutcome(segment: 0, path: "ai", reason: "always+model-timeout 8.0s")
        review.cleanupOutcome(segment: 1, path: "ai", reason: "phrase-restart")
        review.join(segment: 1, decision: .gluedBreath)
    }

    private let delivery = DictationReview.Delivery(
        injection: .init(text: "Hi my name is my name is Aram.", target: "org.tabby", method: "paste"),
        timings: .init(totalSeconds: 1.2, tailSeconds: 0.5, outstandingSeconds: 0.9),
        mode: "localOnly", engine: "parakeet", flags: ["cleanup_coalesce": true])

    func testWithTheKeyTheRecordCarriesEverythingAttributedToItsSegment() async throws {
        let review = DictationReview(keepsContent: true)
        await drive(review)
        let record = review.finish(delivery)
        XCTAssertEqual(record.segments.map(\.index), [0, 1])
        XCTAssertEqual(record.segments[0].raw, "hi my name is")
        XCTAssertEqual(record.segments[0].audioMs, 900)
        XCTAssertEqual(record.segments[0].asrMs, 120)
        XCTAssertEqual(record.segments[1].corrected, "my name is Aram")
        XCTAssertEqual(record.segments[1].joinedBy, .gluedBreath)
        XCTAssertNil(record.segments[0].joinedBy)
        XCTAssertEqual(record.segments[0].cleanupPath, "ai")
        XCTAssertEqual(record.chunks.map(\.segments), [[0], [1]], "chunks are attributed to their span, in segment order")
        let restart = try XCTUnwrap(record.chunks.last)
        XCTAssertEqual(restart.input, "my name is Aram")
        XCTAssertEqual(restart.repairHint, "phrase-restart")
        XCTAssertEqual(restart.attempts.map(\.kind), [.repair, .generic])
        XCTAssertEqual(restart.attempts[0].gateRejection, "truncation")
        XCTAssertEqual(restart.attempts[1].proposal, "My name is Aram.")
        XCTAssertEqual(restart.outcome, .modelAccepted)
        let failed = record.chunks[0]
        XCTAssertEqual(failed.outcome, .modelFailed)
        XCTAssertEqual(failed.reason, "timeout 8.0s")
        XCTAssertEqual(failed.attempts[0].failure, "timeout 8.0s")
        XCTAssertEqual(record.finalText, "Hi my name is my name is Aram.")
        XCTAssertEqual(record.targetBundleID, "org.tabby")
        XCTAssertEqual(record.injectionMethod, "paste")
        XCTAssertEqual(record.versions.schema, LocalReviewVersions.schema)
        XCTAssertEqual(record.versions.flags["cleanup_coalesce"], true)
        XCTAssertNil(record.reference)
    }

    func testWithoutTheKeyNoTextIsRetainedButTheCountsAreReal() async {
        let review = DictationReview(keepsContent: false)
        await drive(review)
        let record = review.finish(delivery)
        XCTAssertEqual(record.finalText, "")
        XCTAssertNil(record.targetBundleID)
        XCTAssertTrue(record.segments.allSatisfy { $0.raw.isEmpty && $0.corrected.isEmpty })
        XCTAssertTrue(record.chunks.allSatisfy { $0.input.isEmpty && $0.delivered.isEmpty && $0.attempts.allSatisfy { $0.proposal == nil } })
        XCTAssertEqual(record.chunks.map(\.outcome), [.modelFailed, .modelAccepted], "outcomes are content-free and stay")
        XCTAssertEqual(record.counts, review.counts)
        XCTAssertEqual(review.counts.chunks, 2)
        XCTAssertEqual(review.counts.modelAccepted, 1)
        XCTAssertEqual(review.counts.modelFailed, 1)
        XCTAssertEqual(review.counts.retried, 1)
        XCTAssertEqual(review.counts.rejections, ["truncation": 1])
        XCTAssertEqual(review.counts.failures, ["timeout 8.0s": 1])
        XCTAssertEqual(review.counts.seamsGluedBreath, 1)
    }

    func testCountsSummaryAndAnalyticsPropertiesAreContentFree() {
        var counts = CleanupCounts()
        counts.chunks = 4; counts.modelAccepted = 1; counts.rulesAfterRejection = 1; counts.budgetSkipped = 1
        counts.notAttempted = ["tier-basic": 1]
        counts.rejections = ["unlicensed-deletion": 1]; counts.seamsSentenceEnd = 2; counts.seamsGluedBreath = 1
        XCTAssertEqual(counts.summary, "cleanup a1 r1(unlicensed-deletion×1) f0 o0 b1 n1(tier-basic×1) · seams e2 g1 c0 x0 a0 r0")
        let props = counts.analyticsProperties
        XCTAssertEqual(props["cleanup_accepted"], 1)
        XCTAssertEqual(props["cleanup_budget_skipped"], 1)
        XCTAssertEqual(props["cleanup_not_attempted"], 1)
        XCTAssertEqual(props["skip_tier_basic"], 1)
        XCTAssertEqual(props["gate_unlicensed_deletion"], 1)
        XCTAssertEqual(props["seams_glued"], 1)
        XCTAssertTrue(props.values.allSatisfy { $0 >= 0 })
        XCTAssertEqual(CleanupCounts().summary, "cleanup a0 r0 f0 o0 b0 n0", "no seams: no seams part")
        // Seam verdicts (decision 1): their count appears once one was applied.
        counts.seamsRuled = 1
        XCTAssertEqual(counts.summary, "cleanup a1 r1(unlicensed-deletion×1) f0 o0 b1 n1(tier-basic×1) · seams e2 g1 c0 x0 a0 r0 v1")
        XCTAssertEqual(counts.analyticsProperties["seams_ruled"], 1)
        let review = DictationReview(keepsContent: false)
        review.join(segment: 1, decision: .seamComma)
        review.join(segment: 2, decision: .seamNothing)
        XCTAssertEqual(review.counts.seamsRuled, 2)
        XCTAssertEqual(review.counts.summary, "cleanup a0 r0 f0 o0 b0 n0 · seams e0 g0 c0 x0 a0 r0 v2")
    }

    func testChunksKeepTheirArrivalOrderWithinASegment() async {
        let review = DictationReview(keepsContent: true)
        await LocalCleanup.$chunkSpan.withValue([0]) {
            for word in ["one", "two", "three", "four", "five", "six", "seven", "eight"] {
                review.chunkStarted(input: word, repairHint: nil)
                review.chunkDelivered(word, outcome: .rulesOnly, reason: nil)
            }
        }
        XCTAssertEqual(review.finish(delivery).chunks.map(\.delivered), ["one", "two", "three", "four", "five", "six", "seven", "eight"],
                       "order within a segment is the order the loop produced")
    }

    func testAReCleanAcrossAPauseSpansBothSegmentsAndAChunkOutsideAnySegmentStillCounts() async {
        let review = DictationReview(keepsContent: true)
        await LocalCleanup.$chunkSpan.withValue([0, 1]) {
            review.chunkStarted(input: "bob wait no alice", repairHint: "marker")
            review.chunkDelivered("Alice.", outcome: .modelAccepted, reason: nil)
        }
        review.chunkStarted(input: "x", repairHint: nil)
        review.chunkDelivered("X.", outcome: .rulesOnly, reason: nil)
        let record = review.finish(delivery)
        XCTAssertEqual(record.chunks.map(\.segments), [[-1], [0, 1]])
        XCTAssertEqual(review.counts.rulesOnly, 1)
    }

    func testANotAttemptedSegmentIsOneCountedChunk() {
        let review = DictationReview(keepsContent: true)
        review.segment(0, boundary: .tail, raw: "hello there", corrected: "hello there")
        XCTAssertFalse(review.sawChunks(for: 0))
        review.notAttempted(segment: 0, text: "Hello there.", reason: "tier-basic")
        XCTAssertTrue(review.sawChunks(for: 0))
        let record = review.finish(delivery)
        XCTAssertEqual(record.chunks.map(\.outcome), [.notAttempted])
        XCTAssertEqual(record.chunks[0].reason, "tier-basic")
        XCTAssertEqual(record.counts.chunks, 1)
        XCTAssertEqual(record.counts.notAttempted, ["tier-basic": 1])
    }

    /// A copy written by an earlier schema (no `seamsRestart`, no `audioFile`)
    /// still decodes: the corpus bench reads whatever is on disk.
    func testAnOlderCopyStillDecodes() throws {
        let review = DictationReview(keepsContent: true)
        review.segment(0, boundary: .tail, raw: "hi", corrected: "hi")
        var record = review.finish(delivery)
        record.counts.seamsRestart = 1
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(String(data: try encoder.encode(record), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"seamsRestart\":1,", with: "").replacingOccurrences(of: ",\"seamsRestart\":1", with: "")
        XCTAssertFalse(json.contains("seamsRestart"))
        let decoded = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.counts.seamsRestart, 0, "the missing count is its default")
        XCTAssertNil(decoded.audioFile)
        XCTAssertEqual(decoded.segments.count, 1)
    }
}
