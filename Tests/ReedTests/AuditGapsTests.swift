import XCTest
@testable import Reed

/// Small uncovered arms from the 2026-08-30 suite audit, each with a real
/// failure mode: error → remedy routing for recorder failures, the latency
/// analytics buckets (an off-by-one leaks precision, i.e. privacy), and the
/// network gate protocol being armed with no mode to consult.
final class AuditGapsTests: XCTestCase {
    // MARK: error → remedy routing (assert routing, never copy strings)

    func testMicDeniedRoutesToPermissions() {
        let err = DictationError.classify(AudioRecorder.RecorderError.micDenied)
        XCTAssertEqual(err.action, .openPermissions)
        XCTAssertEqual(err.severity, .actionable)
    }

    func testDeviceFormatMismatchRoutesToSettingsNotADeadEnd() {
        let err = DictationError.classify(AudioRecorder.RecorderError.deviceFormatMismatch)
        XCTAssertEqual(err.action, .openSettings, "the user can fix this by picking another mic")
        XCTAssertEqual(err.severity, .actionable)
    }

    func testNoInputIsActionableWithoutAFalseRemedy() {
        let err = DictationError.classify(AudioRecorder.RecorderError.noInput)
        XCTAssertEqual(err.action, Optional.some(.none), "no settings pane conjures a microphone")
        XCTAssertEqual(err.severity, .actionable)
    }

    func testConverterFailureIsHard() {
        let err = DictationError.classify(AudioRecorder.RecorderError.converterFailed)
        XCTAssertEqual(err.severity, .hard, "there is nothing the user can do differently")
    }

    // MARK: latency buckets — every boundary, both sides

    func testLatencyBucketBoundaries() {
        let expectations: [(Int, String)] = [
            (0, "0-1s"), (999, "0-1s"), (1_000, "1-5s"), (4_999, "1-5s"),
            (5_000, "5-10s"), (9_999, "5-10s"), (10_000, "10-15s"), (14_999, "10-15s"),
            (15_000, "15-30s"), (29_999, "15-30s"), (30_000, "30-60s"), (59_999, "30-60s"),
            (60_000, "60-120s"), (119_999, "60-120s"), (120_000, "120-300s"),
            (299_999, "120-300s"), (300_000, "300s+"),
        ]
        for (ms, bucket) in expectations {
            XCTAssertEqual(Analytics.latencyBucket(ms), bucket, "\(ms) ms")
        }
    }

    // MARK: the gate is always armed

    func testGateProtocolInterceptsAnUnlistedHostWhateverAnOldModeSetting() {
        // Builds before 2026-09-15 persisted "pipelineMode" = "cloud", which
        // disarmed the gate. Nothing reads it now; a leftover value must not
        // open a hole.
        let saved = UserDefaults.standard.object(forKey: "pipelineMode")
        defer { UserDefaults.standard.set(saved, forKey: "pipelineMode") }
        UserDefaults.standard.set("cloud", forKey: "pipelineMode")
        let request = URLRequest(url: URL(string: "https://api.groq.com/v1")!)
        XCTAssertTrue(GateURLProtocol.canInit(with: request),
                      "a non-allowlisted host is intercepted (and killed)")
    }
}
