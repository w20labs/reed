import XCTest
@testable import Reed

/// The config-change decision table (AudioRecorder.configChangeAction) —
/// the pure heart of the pin-race fix. Field evidence this pins: reed.log
/// 2026-08-05 07:21:51, where the pin's own notification landed AFTER
/// capture was armed, was "ignored", and the recording never saw a frame;
/// every retry then reused the dead graph.
final class ConfigChangeRecoveryTests: XCTestCase {

    func testMidCaptureChangeAlwaysInterrupts() {
        // A stopped engine under an active capture is fatal no matter who
        // caused it — our own fresh pin included. This is the exact case the
        // old boolean got wrong by "ignoring" it.
        XCTAssertEqual(
            AudioRecorder.configChangeAction(capturing: true, tapLive: true, msSincePin: 5),
            .interruptCapture)
        XCTAssertEqual(
            AudioRecorder.configChangeAction(capturing: true, tapLive: true, msSincePin: nil),
            .interruptCapture)
        XCTAssertEqual(
            AudioRecorder.configChangeAction(capturing: true, tapLive: false, msSincePin: 5_000),
            .interruptCapture)
    }

    func testLiveTapMakesEvenARecentEchoInvalidate() {
        // The second field failure (reed.log 18:46:35): the pin's echo landed
        // idle but AFTER the tap was installed — the tap belonged to the old
        // graph and never fired again. Absorb is only safe with no tap.
        XCTAssertEqual(
            AudioRecorder.configChangeAction(capturing: false, tapLive: true, msSincePin: 133),
            .invalidate)
        XCTAssertEqual(
            AudioRecorder.configChangeAction(capturing: false, tapLive: true, msSincePin: 5),
            .invalidate)
    }

    func testRecentSelfPinAbsorbedOnlyBeforeTheTapExists() {
        // The one safe absorb: our pin's echo arriving inside prewarm's
        // settle window, before installTap — nothing to tear down.
        XCTAssertEqual(
            AudioRecorder.configChangeAction(capturing: false, tapLive: false, msSincePin: 5),
            .absorb)
        XCTAssertEqual(
            AudioRecorder.configChangeAction(
                capturing: false, tapLive: false,
                msSincePin: AudioRecorder.selfInflictedGraceMs - 1),
            .absorb)
    }

    func testStaleOrForeignChangeInvalidates() {
        // No pin stamp, or one older than the grace window, means a genuine
        // device change — the timestamp (unlike the old one-shot boolean)
        // can't leak from a pin that changed nothing and emitted no
        // notification.
        XCTAssertEqual(
            AudioRecorder.configChangeAction(capturing: false, tapLive: false, msSincePin: nil),
            .invalidate)
        XCTAssertEqual(
            AudioRecorder.configChangeAction(
                capturing: false, tapLive: false,
                msSincePin: AudioRecorder.selfInflictedGraceMs + 1),
            .invalidate)
    }
}
