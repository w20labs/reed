import XCTest
@testable import Reed

/// The Bluetooth warm-up contract (design: HUD · Bluetooth warm-up).
///
/// macOS must switch AirPods from A2DP to HFP/SCO before a single frame is
/// audible — 0.5-1.5 s in which the mic is genuinely deaf. Claiming "Listening"
/// there is not an approximation, it's false, and the user's opening words
/// don't exist. These pin the surfaces that must tell the truth about it.
final class BluetoothWarmupTests: XCTestCase {

    // MARK: - the readiness cue

    @MainActor
    func testWiredWarmingStillReadsAsListening() {
        // The decided rule for every non-Bluetooth mic is unchanged: warming
        // reads as Listening, because a wired mic has real signal from frame
        // one and delaying its cue would be a regression.
        let vm = OverlayViewModel()
        vm.state = .warming
        vm.micIsPreparing = false
        XCTAssertEqual(OverlayView.labelForTesting(vm), "Listening")
    }

    @MainActor
    func testBluetoothWarmingReadsAsPreparingMic() {
        let vm = OverlayViewModel()
        vm.state = .warming
        vm.micIsPreparing = true
        XCTAssertEqual(OverlayView.labelForTesting(vm), "Preparing mic…")
    }

    @MainActor
    func testPreparingEndsWhenTheMicGoesLive() {
        // Once real signal arrives the pill must become the ordinary Listening
        // state — the preparing copy is for the deaf window only.
        let vm = OverlayViewModel()
        vm.state = .recording
        vm.micIsPreparing = false
        XCTAssertEqual(OverlayView.labelForTesting(vm), "Listening")
    }
}
