import XCTest
@testable import Reed

/// Review 2026-09-04/05 (P1): a segment worker takes its dictation's
/// collector as a value captured at the seal, never by reading the
/// coordinator's `review` after its first await. Driven through the
/// PRODUCTION path — `enqueue` → `cleanSegment` → `reviewedCleanup` — with
/// the recognizer parked mid-segment so the press can end underneath it.
@MainActor
final class ReviewIsolationTests: XCTestCase {
    private var coordinator: Coordinator!
    private var savedOnboarding: Any?
    private var savedTier: String?
    private let wav = WAVWriter.wrap(pcm: Data(count: 3_200), sampleRate: 16_000, channels: 1, bitsPerSample: 16)

    override func setUp() {
        super.setUp()
        savedOnboarding = UserDefaults.standard.object(forKey: OnboardingState.completedKey)
        savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
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

    /// A recognizer that reports it was entered, then waits to be released.
    private struct ParkedRecognizer {
        let entered: AsyncStream<Void>
        let release: AsyncStream<Void>.Continuation
    }

    private func parkRecognizer(returning text: String) -> ParkedRecognizer {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        Coordinator.transcribeOverride = { _ in
            entered.continuation.yield(())
            for await _ in release.stream { break }
            return text
        }
        return ParkedRecognizer(entered: entered.stream, release: release.continuation)
    }

    private let delivery = DictationReview.Delivery(injection: .init(text: "", target: nil, method: "ax"),
                                                    timings: .init(totalSeconds: 0), mode: "localOnly", engine: "parakeet")

    /// One sealed segment enqueued for the current press; its worker is
    /// parked inside the recognizer when this returns.
    private func enqueueParkedSegment(_ recognizer: ParkedRecognizer) async throws -> Task<String?, Never> {
        coordinator.overlap.arm()
        let workers = coordinator.enqueue([.init(wav: wav, reason: .pause, rmsDB: -20)])
        for await _ in recognizer.entered { break }
        return try XCTUnwrap(workers.first)
    }

    func testAWorkerFromTheLastPressCannotWriteIntoTheNextPressesCollector() async throws {
        coordinator.beginReview()
        let collectorA = try XCTUnwrap(coordinator.review)
        let recognizer = parkRecognizer(returning: "words from press A")
        let workerA = try await enqueueParkedSegment(recognizer)

        // Press A is aborted under the worker (cancelled, not awaited); press B begins.
        coordinator.abortPress()
        coordinator.beginReview()
        let collectorB = try XCTUnwrap(coordinator.review)
        XCTAssertFalse(collectorA === collectorB)
        recognizer.release.yield(())
        _ = await workerA.value

        XCTAssertEqual(collectorA.finish(delivery).segments.map(\.index), [0], "A's late work lands in A")
        XCTAssertEqual(collectorA.counts.chunks, 1)
        XCTAssertTrue(collectorB.finish(delivery).segments.isEmpty, "B never sees A's words")
        XCTAssertEqual(collectorB.counts, CleanupCounts())
    }

    func testAWorkerCancelledByTheFallbackCannotWriteIntoTheSinglePassRecord() async throws {
        coordinator.beginReview()
        let speculative = try XCTUnwrap(coordinator.review)
        let recognizer = parkRecognizer(returning: "speculative words")
        let worker = try await enqueueParkedSegment(recognizer)

        // The fallback: workers cancelled, not awaited; single-pass gets its collector.
        coordinator.abandonOverlapForSinglePass()
        let singlePass = try XCTUnwrap(coordinator.review)
        XCTAssertFalse(singlePass === speculative, "a fresh collector, not the cleared old one")
        XCTAssertEqual(singlePass.startedAt, speculative.startedAt, "same dictation")
        XCTAssertEqual(singlePass.keepsContent, speculative.keepsContent)
        recognizer.release.yield(())
        _ = await worker.value

        XCTAssertEqual(singlePass.counts, CleanupCounts(), "the late worker's chunk is not in the single-pass record")
        XCTAssertTrue(singlePass.finish(delivery).segments.isEmpty)
        XCTAssertEqual(speculative.counts.chunks, 1, "it landed in the abandoned collector, which nobody reads")
    }

    func testAbandoningWithoutACollectorIsHarmless() {
        coordinator.abandonOverlapForSinglePass()
        XCTAssertNil(coordinator.review)
    }

    func testOutsideAnyBindingTheLoopHasNoObserver() {
        XCTAssertNil(LocalCleanup.observer)
        XCTAssertNil(LocalCleanup.chunkSpan)
    }
}
