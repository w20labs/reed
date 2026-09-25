import XCTest
@testable import Reed

/// Regression test for a real-world bug: macOS's own "quit and reopen Reed"
/// prompt (shown right after granting the mic permission from the onboarding
/// step's System Settings deep link) drives the user to quit the app via
/// `NSApplication.terminate(nil)`. AppKit closes open windows as part of
/// that shutdown, firing the onboarding window's `willClose` exactly like a
/// user dismissal — before this fix, that unconditionally called
/// `OnboardingState.markComplete()`, permanently hiding onboarding on the
/// next launch even though the user never finished it. See
/// `Coordinator.isTerminating` / `Coordinator+Onboarding.swift`.
@MainActor
final class OnboardingWindowCloseTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey)
        UserDefaults.standard.removeObject(forKey: OnboardingState.savedStepKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey)
        UserDefaults.standard.removeObject(forKey: OnboardingState.savedStepKey)
        super.tearDown()
    }

    func testQuittingWhileOnboardingIsOpenDoesNotMarkComplete() {
        let coordinator = Coordinator()
        coordinator.openOnboarding()
        XCTAssertNotNil(coordinator.onboardingWindow)

        coordinator.isTerminating = true
        coordinator.onboardingWindow?.close()

        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: OnboardingState.completedKey),
            "quitting mid-onboarding must not burn the one-shot completed flag"
        )
        XCTAssertTrue(
            OnboardingState.shouldShowOnFirstLaunch(),
            "onboarding must still show on the next launch after a mid-flow quit"
        )
    }

    func testUserClosingOnboardingDefersInsteadOfCompleting() {
        // Semantics inverted by P12 (2026-08-07): the red close button used
        // to mark onboarding complete — which let a dismissal skip terms
        // acceptance, the permission coaching, and the model download, and
        // then armed the hotkey on a pipeline that could only fail. Closing
        // now defers: the flag stays unset, the hotkey summons the window
        // back (Coordinator.start's gate), and completion happens only via
        // "Get started" or a Skip button.
        let coordinator = Coordinator()
        coordinator.openOnboarding()
        XCTAssertNotNil(coordinator.onboardingWindow)

        // isTerminating stays false — this is the red-close-button path.
        coordinator.onboardingWindow?.close()

        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: OnboardingState.completedKey),
            "dismissal must not complete onboarding — setup finishes only via Get started/Skip"
        )
        XCTAssertTrue(
            OnboardingState.shouldShowOnFirstLaunch(),
            "onboarding must return on the next launch (and the hotkey summons it meanwhile)"
        )
    }
}
