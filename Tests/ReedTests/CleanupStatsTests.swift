import XCTest
@testable import Reed

/// The adaptive cleanup deadline and the failure record (2026-08-29).
final class CleanupStatsTests: XCTestCase {
    func testDeadlineIsTheCeilingUntilEnoughSamples() {
        XCTAssertEqual(CleanupStats.deadline(forDurations: []), 8)
        XCTAssertEqual(CleanupStats.deadline(forDurations: [0.6, 0.6, 0.6, 0.6]), 8)
    }

    func testDeadlineIsFourTimesTheMedianWithinBounds() {
        XCTAssertEqual(CleanupStats.deadline(forDurations: [0.6, 0.6, 0.6, 0.6, 0.6]), 2.5, "floor: 4 × 0.6 = 2.4 → 2.5")
        XCTAssertEqual(CleanupStats.deadline(forDurations: [0.9, 1.0, 1.0, 1.1, 1.2]), 4.0, accuracy: 0.001)
        XCTAssertEqual(CleanupStats.deadline(forDurations: [2.0, 2.1, 2.5, 3.0, 2.2]), 8, "a slow Mac keeps the full deadline")
        // One outlier does not move the median.
        XCTAssertEqual(CleanupStats.deadline(forDurations: [0.6, 0.6, 8.0, 0.6, 0.6]), 2.5)
    }

    func testTimeoutsAreCountedAndNothingElseIsKeptAboutAFailure() async {
        let stats = CleanupStats()
        await stats.recordFailure(timedOut: true)
        await stats.recordFailure(timedOut: false)
        let timeouts = await stats.timeouts
        let calls = await stats.calls
        XCTAssertEqual(timeouts, 1)
        XCTAssertEqual(calls, 2)
        // The failure class travels in the call's reply (LocalCleanup.ModelReply).
        XCTAssertTrue(LocalCleanup.ModelReply.failed("timeout 2.5s").timedOut)
        XCTAssertFalse(LocalCleanup.ModelReply.failed("error").timedOut)
        XCTAssertEqual(LocalCleanup.ModelReply.text("ok").text, "ok")
    }

    func testTimingsLineNamesEngineAndWarmth() {
        let line = DebugTimings.line(total: 1.2, load: nil, denoise: 0.0, asr: 0.2, clean: 0.6,
                                     tier: "on-device AI", engine: "parakeet", warm: 3)
        XCTAssertEqual(line, "total 1.2s · denoise 0.0s · asr 0.2s·parakeet · on-device AI 0.6s · warm 3")
        XCTAssertEqual(DebugTimings.line(total: 1.0, load: nil, asr: 0.8, clean: 0.2, tier: "basic"),
                       "total 1.0s · asr 0.8s · basic 0.2s")
    }
}
