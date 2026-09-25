import XCTest
@testable import Reed

/// P16 through the coordinator: a local press begins a collector, a
/// segment's cleanup is recorded under its index with timings and a
/// not-attempted chunk on the default tier, delivery takes the injector's
/// receipt and yields the counts, a fallback discards speculative work,
/// and a cloud press has no collector. Transcription is the test seam;
/// nothing is written to disk (this process has no review directory).
@MainActor
final class LocalReviewPipelineTests: XCTestCase {
    private var coordinator: Coordinator!
    private var savedOnboarding: Any?
    private var savedTier: String?
    private let wav = WAVWriter.wrap(pcm: Data(count: 3_200), sampleRate: 16_000, channels: 1, bitsPerSample: 16)

    override func setUp() {
        super.setUp()
        savedOnboarding = UserDefaults.standard.object(forKey: OnboardingState.completedKey)
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
        // The default tier on any Mac: rules only, the model never asked.
        savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.basic)
        coordinator = Coordinator()
    }

    override func tearDown() {
        Coordinator.transcribeOverride = nil
        if let savedOnboarding { UserDefaults.standard.set(savedOnboarding, forKey: OnboardingState.completedKey) }
        else { UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey) }
        if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
        else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        super.tearDown()
    }

    private let receipt = TextInjector.Receipt(text: "Hello from the segment.", target: "org.tabby", method: "paste")

    func testAPressCollectsItsSegmentWithTimingsAndDeliveryYieldsCounts() async throws {
        Coordinator.transcribeOverride = { _ in "hello from the segment" }
        coordinator.beginReview()
        let collector = try XCTUnwrap(coordinator.review)
        XCTAssertFalse(collector.keepsContent, "no review key in this process: content is not kept")
        XCTAssertNil(LocalCleanup.observer, "the collector is never held anywhere global")

        let text = await coordinator.cleanSegment(wav: wav, rmsDB: -20, index: 2, boundary: .pause, into: collector)
        XCTAssertNotNil(text)
        let counts = try XCTUnwrap(coordinator.deliverReview(injection: receipt, timings: .init(totalSeconds: 0.5)))
        XCTAssertEqual(counts.chunks, 1, "the basic tier never asks the model, and that is counted as one chunk")
        XCTAssertEqual(counts.notAttempted, ["tier-basic": 1])
        let record = collector.finish(.init(injection: .init(text: "", target: nil, method: "ax"),
                                            timings: .init(totalSeconds: 0.5), mode: "localOnly", engine: "parakeet"))
        XCTAssertEqual(record.segments.map(\.index), [2])
        XCTAssertEqual(record.segments[0].boundary, .pause)
        XCTAssertEqual(record.segments[0].audioMs, 100, "3 200 bytes of 16 kHz int16 is 100 ms")
        XCTAssertNotNil(record.segments[0].asrMs)
        XCTAssertNotNil(record.segments[0].cleanupPath)
        XCTAssertEqual(record.chunks.map(\.outcome), [.notAttempted])
        XCTAssertEqual(record.segments[0].raw, "", "without the key the recognizer's words are not retained")

        coordinator.endReview()
        XCTAssertNil(coordinator.review)
    }

    /// The recording rides delivery to the store only while content is kept.
    func testDeliveryPassesTheRecordingAlongWithTheReceipt() {
        coordinator.beginReview()
        let collector = coordinator.review!
        XCTAssertFalse(collector.keepsContent)
        _ = coordinator.deliverReview(injection: receipt, timings: .init(totalSeconds: 0.1), audio: wav)
        // No key in this process: nothing is written (the store has no directory), and
        // the record itself never carries audio bytes — only the store names the file.
        let record = collector.finish(.init(injection: .init(text: "", target: nil, method: "ax"),
                                            timings: .init(totalSeconds: 0.1), mode: "localOnly", engine: "parakeet"))
        XCTAssertNil(record.audioFile)
    }

    func testDeliveryRecordsTheReceiptNotThePipelinesString() {
        coordinator.beginReview()
        let collector = coordinator.review!
        _ = coordinator.deliverReview(injection: .init(text: "sanitized text", target: "com.apple.Terminal", method: "paste"),
                                      timings: .init(totalSeconds: 0.1))
        let record = collector.finish(.init(injection: .init(text: "sanitized text", target: "com.apple.Terminal", method: "paste"),
                                            timings: .init(totalSeconds: 0.1), mode: "localOnly", engine: "parakeet"))
        XCTAssertEqual(record.finalText, "", "content is not kept without the key")
        XCTAssertEqual(record.injectionMethod, "paste", "but the path that reached the destination is")
    }

    func testAFallbackReplacesTheCollectorBeforeSinglePass() async throws {
        Coordinator.transcribeOverride = { _ in "speculative words" }
        coordinator.beginReview()
        let speculative = try XCTUnwrap(coordinator.review)
        _ = await coordinator.cleanSegment(wav: wav, rmsDB: -20, index: 0, boundary: .pause, into: speculative)
        XCTAssertEqual(speculative.counts.chunks, 1)
        coordinator.abandonOverlapForSinglePass()
        let fresh = try XCTUnwrap(coordinator.review, "a collector stays for the single-pass result")
        XCTAssertFalse(fresh === speculative)
        XCTAssertEqual(fresh.counts, CleanupCounts())
        XCTAssertEqual(coordinator.overlap.segmentCount, 0, "the session was reset in the same step")
    }

    func testAnAbortedPressEndsTheReview() {
        coordinator.beginReview()
        XCTAssertNotNil(coordinator.review)
        coordinator.abortPress()
        XCTAssertNil(coordinator.review)
    }

    func testNotAttemptedReasonsNameTheTier() {
        XCTAssertEqual(Coordinator.notAttemptedReason(.init(text: "", path: .raw, reason: nil)), "tier-off")
        XCTAssertEqual(Coordinator.notAttemptedReason(.init(text: "", path: .basic, reason: nil)), "tier-basic")
        XCTAssertEqual(Coordinator.notAttemptedReason(.init(text: "", path: .basic, reason: "ai-unavailable")), "ai-unavailable")
        XCTAssertEqual(Coordinator.notAttemptedReason(.init(text: "", path: .fast, reason: "fast")), "fast-path")
    }
}
