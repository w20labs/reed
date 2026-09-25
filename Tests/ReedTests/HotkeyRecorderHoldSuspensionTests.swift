import XCTest
@testable import Reed

/// Regression test for a real-world bug: on a fresh install the default
/// push-to-talk trigger is the bare ⌃⌥ hold, and `Coordinator`'s global
/// `ModifierHoldMonitor` for it runs at all times — including while the
/// onboarding (or Settings) hotkey field is armed and trying to record a
/// new shortcut. Holding ⌃⌥ to type a combo like ⌃⌥R (or to just confirm the
/// hold) was indistinguishable from actually holding to dictate, so real
/// dictation started mid-recording and then read the following keypress as
/// "that's a shortcut, cancel" — the field never got a clean capture.
/// `HotkeyRecorderField` now posts `.hotkeyRecorderArmedDidChange` on
/// arm/disarm, and `Coordinator` suspends `holdMonitor` while any field is
/// armed. See `Coordinator.configureHoldMonitor`.
@MainActor
final class HotkeyRecorderHoldSuspensionTests: XCTestCase {
    func testArmingARecorderFieldSuspendsTheHoldMonitor() {
        let coordinator = Coordinator()
        XCTAssertNotNil(coordinator.holdMonitor.currentTrigger, "the default hold should be armed at launch")

        NotificationCenter.default.post(name: .hotkeyRecorderArmedDidChange, object: true)
        XCTAssertNil(
            coordinator.holdMonitor.currentTrigger,
            "recording a shortcut must stand the global hold down, or the same ⌃⌥ gesture starts real dictation"
        )

        NotificationCenter.default.post(name: .hotkeyRecorderArmedDidChange, object: false)
        XCTAssertNotNil(coordinator.holdMonitor.currentTrigger, "disarming should restore the hold")
    }

    func testTwoFieldsOpenSideBySideDontResumeTheHoldEarly() {
        // Onboarding and Settings can both be open with their own recorder
        // field (see HotkeyRecorderField's doc comment) — one disarming
        // must not resume the hold monitor while the other is still armed.
        let coordinator = Coordinator()

        NotificationCenter.default.post(name: .hotkeyRecorderArmedDidChange, object: true)  // field A arms
        NotificationCenter.default.post(name: .hotkeyRecorderArmedDidChange, object: true)  // field B arms
        NotificationCenter.default.post(name: .hotkeyRecorderArmedDidChange, object: false) // field A disarms
        XCTAssertNil(
            coordinator.holdMonitor.currentTrigger,
            "field B is still recording — the hold must stay suspended"
        )

        NotificationCenter.default.post(name: .hotkeyRecorderArmedDidChange, object: false) // field B disarms
        XCTAssertNotNil(coordinator.holdMonitor.currentTrigger, "both fields disarmed — the hold should resume")
    }

    func testTriggerChangeWhileRecordingDoesNotRearmTheHold() {
        // Review 2026-08-26: onboarding's "Use ⌃⌥ instead" posts
        // PushToTalkTrigger.didChange, and that observer re-armed the hold
        // unconditionally — while the Settings field (open side by side) was
        // still capturing, defeating the very stand-down the counter exists
        // for. The change must wait until the field disarms.
        let coordinator = Coordinator()

        NotificationCenter.default.post(name: .hotkeyRecorderArmedDidChange, object: true)
        XCTAssertNil(coordinator.holdMonitor.currentTrigger)

        NotificationCenter.default.post(name: PushToTalkTrigger.didChange, object: nil)
        XCTAssertNil(coordinator.holdMonitor.currentTrigger,
                     "a trigger change while a field is recording must not re-arm the hold")

        NotificationCenter.default.post(name: .hotkeyRecorderArmedDidChange, object: false)
        XCTAssertNotNil(coordinator.holdMonitor.currentTrigger,
                        "the field disarming restores the hold on the current trigger")
    }
}
