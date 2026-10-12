import XCTest
@testable import Reed

/// Tests that instantiate the real input node open the default input
/// device. On Bluetooth that flips the headset into its call profile and
/// the user's audio turns robotic for the length of the run (2026-10-12,
/// AirPods during the PR #25 runs) — so those tests skip there.
func skipIfDefaultInputIsBluetooth() throws {
    if AudioInputDevice.defaultInput()?.isBluetooth == true {
        throw XCTSkip("default input is Bluetooth; touching it switches the headset to call audio")
    }
}
