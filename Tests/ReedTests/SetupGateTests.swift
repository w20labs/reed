import XCTest
@testable import Reed

/// The hotkey's setup gate (Coordinator+DictationStart). Reed has no terms to
/// accept since 2026-09-26, so an unfinished setup blocks dictation only while
/// the speech model is missing.
final class SetupGateTests: XCTestCase {
    func testMissingModelDuringSetupBringsSetupForward() {
        XCTAssertTrue(Coordinator.setupBlocksDictation(onboardingPending: true, modelInstalled: false))
    }

    func testAnInstalledModelAllowsDictationMidSetup() {
        // The Done step invites a test dictation before "Get started"; nothing
        // else, such as a recorded acceptance, may stand in the way.
        XCTAssertFalse(Coordinator.setupBlocksDictation(onboardingPending: true, modelInstalled: true))
    }

    func testFinishedSetupNeverBlocks() {
        XCTAssertFalse(Coordinator.setupBlocksDictation(onboardingPending: false, modelInstalled: false))
        XCTAssertFalse(Coordinator.setupBlocksDictation(onboardingPending: false, modelInstalled: true))
    }
}
