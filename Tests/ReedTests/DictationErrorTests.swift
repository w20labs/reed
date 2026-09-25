import XCTest
@testable import Reed

/// The curated error map: every recorder failure must become human copy + the
/// right fix route, and must NEVER leak the raw error text into the user-facing
/// headline (that's the whole point of the breadcrumb design).
final class DictationErrorTests: XCTestCase {
    func testMicDeniedRoutesToSettings() {
        let error = DictationError.classify(AudioRecorder.RecorderError.micDenied)
        XCTAssertEqual(error.action, .openPermissions)
        XCTAssertEqual(error.severity, .actionable)
        XCTAssertTrue(error.headline.lowercased().contains("microphone"))
    }

    func testAnUnknownErrorIsHardAndOffersNoFalseRemedy() {
        let error = DictationError.classify(NSError(domain: "test", code: 1))
        XCTAssertEqual(error.severity, .hard)
        XCTAssertNil(error.actionTitle)
    }

    func testHeadlineNeverLeaksTheRawError() {
        let error = DictationError.classify(NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 401: {\"secret\":\"leak\"}"]))
        XCTAssertFalse(error.headline.contains("HTTP"))
        XCTAssertFalse(error.headline.contains("{"))
        // …but the raw detail is preserved for the collapsible menu row + Sentry.
        XCTAssertTrue(error.raw.contains("HTTP 401"))
    }
}
