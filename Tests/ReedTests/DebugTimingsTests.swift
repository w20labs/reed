import XCTest
@testable import Reed

/// The timings line is the app's latency-forensics format ("it felt slow
/// yesterday" runs on these files) — its shape is a contract.
final class DebugTimingsTests: XCTestCase {
    func testLineFormatWithLoad() {
        XCTAssertEqual(
            DebugTimings.line(total: 4.2, load: 1.0, asr: 2.14, clean: 0.31, tier: "basic"),
            "total 4.2s · load 1.0s · asr 2.1s · basic 0.3s")
    }

    func testLineOmitsLoadWhenNil() {
        XCTAssertEqual(
            DebugTimings.line(total: 1.0, load: nil, asr: 0.5, clean: 0.2, tier: "fast"),
            "total 1.0s · asr 0.5s · fast 0.2s")
    }

    func testLineIncludesDenoiseWhenPresent() {
        XCTAssertEqual(
            DebugTimings.line(total: 4.2, load: 1.0, denoise: 0.03, asr: 2.14, clean: 0.31, tier: "basic"),
            "total 4.2s · load 1.0s · denoise 0.0s · asr 2.1s · basic 0.3s")
    }

}
