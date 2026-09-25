import XCTest
@testable import Reed

/// Unit coverage for `DenoiseWatchdog` (declared in `Coordinator+Local.swift`)
/// in isolation from `Denoiser`/ONNX Runtime. The scenario it guards against —
/// a genuinely wedged ONNX call occupying `Denoiser`'s actor executor forever —
/// isn't reproducible in a fast, deterministic unit test, so this exercises the
/// watchdog's own state machine directly instead: starts un-wedged, latches
/// permanently once `markWedged()` is called.
final class DenoiseWatchdogTests: XCTestCase {

    func testMarkWedgedLatchesIsWedged() {
        let watchdog = DenoiseWatchdog()
        watchdog.markWedged()
        XCTAssertTrue(watchdog.isWedged())
    }

}
