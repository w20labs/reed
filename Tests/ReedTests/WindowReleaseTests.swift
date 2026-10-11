import AppKit
import XCTest
@testable import Reed

/// Reed's windows used to be closed but kept, with their SwiftUI tree still
/// mounted: the setup window's 0.4 s poll and welcome animation, and the
/// Settings shortcut field's 0.5 s poll, ran for the rest of the session
/// after the window was gone (2026-10-10, the sibling of the hidden HUD
/// spinner). Closing must release the window and its content.
@MainActor
final class WindowReleaseTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        // Completed, so Coordinator's launch task doesn't open setup by
        // itself while a test waits; the tests open it explicitly.
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
        UserDefaults.standard.removeObject(forKey: OnboardingState.savedStepKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey)
        UserDefaults.standard.removeObject(forKey: OnboardingState.savedStepKey)
        super.tearDown()
    }

    /// Closes `window` and lets the deferred content release run.
    private func closeAndSettle(_ window: NSWindow?) {
        window?.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    func testClosingSetupReleasesTheWindowAndItsContent() {
        let coordinator = Coordinator()
        coordinator.openOnboarding()
        let window = coordinator.onboardingWindow
        XCTAssertNotNil(window?.contentView)

        closeAndSettle(window)

        XCTAssertNil(coordinator.onboardingWindow, "a closed setup window must not stay in its slot")
        XCTAssertNil(window?.contentView, "its SwiftUI tree must be unmounted")
    }

    func testReopeningSetupBuildsAFreshWindow() {
        let coordinator = Coordinator()
        coordinator.openOnboarding()
        let first = coordinator.onboardingWindow
        closeAndSettle(first)

        coordinator.openOnboarding()

        XCTAssertNotNil(coordinator.onboardingWindow?.contentView)
        XCTAssertFalse(coordinator.onboardingWindow === first)
        closeAndSettle(coordinator.onboardingWindow)
    }

    func testClosingSettingsReleasesTheWindowAndItsContent() {
        let coordinator = Coordinator()
        coordinator.openSettings()
        let window = coordinator.settingsWindow
        XCTAssertNotNil(window?.contentView)

        closeAndSettle(window)

        XCTAssertNil(coordinator.settingsWindow)
        XCTAssertNil(window?.contentView)
    }
}
