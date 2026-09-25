import XCTest
@testable import Reed

/// Smoke tests for the onboarding state machine — the completion flag, the
/// step order, and the gates. The actual flow is UI; this guards the logic.
final class OnboardingStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Each test starts from a clean UserDefaults slate for the completion key.
        UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey)
    }

    @MainActor
    func testAdvanceWalksEveryStepInOrder() {
        let state = OnboardingState()
        var seen: [OnboardingState.Step] = [state.step]
        while state.step != .done {
            state.advance()
            seen.append(state.step)
        }
        XCTAssertEqual(seen, [.welcome, .microphone, .accessibility, .hotkey, .onDeviceSetup, .cleanup, .done])
        state.advance()
        XCTAssertEqual(state.step, .done, "advance() from Done stays put")
    }

    @MainActor
    func testBackWalksBackAndClampsAtWelcome() {
        let state = OnboardingState()
        XCTAssertEqual(state.previousStep(before: .done), .cleanup)
        XCTAssertEqual(state.previousStep(before: .onDeviceSetup), .hotkey, "the raw-value gap is walked by position")
        state.back()
        XCTAssertEqual(state.step, .welcome, "back() from the first step should stay put, not underflow")
    }

    @MainActor
    func testEveryStepIsVisibleAndThereAreNoAccountSteps() {
        let state = OnboardingState()
        XCTAssertEqual(state.visibleSteps, OnboardingState.Step.allCases)
        XCTAssertEqual(state.visibleSteps.count, 7)
        XCTAssertEqual(state.visibleSteps.last, .done)
    }

    func testMarkCompleteFlipsTheFlag() {
        XCTAssertFalse(UserDefaults.standard.bool(forKey: OnboardingState.completedKey))
        OnboardingState.markComplete()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: OnboardingState.completedKey))
        // shouldShowOnFirstLaunch must return false once complete is set.
        XCTAssertFalse(OnboardingState.shouldShowOnFirstLaunch())
    }

    // MARK: - Gates

    @MainActor
    func testHotkeyNeverBlocksAdvancing() {
        // The ⌃⌥ hold is a real default that needs no recorded shortcut.
        XCTAssertTrue(OnboardingState().canAdvance(from: .hotkey))
    }

    @MainActor
    func testCleanupIsNeverBlocking() {
        // Cleanup is a preference, not a requirement: with Apple Intelligence
        // off — or on macOS < 26, where it does not exist — cleanup still runs
        // on the rules pass, so there is nothing to wait for.
        XCTAssertTrue(OnboardingState().canAdvance(from: .cleanup))
    }

    @MainActor
    func testOnDeviceSetupGatesOnModelInstalled() {
        let state = OnboardingState()
        // P15: the gate is "the speech model is on disk AND proven to load"
        // — pinned both ways through the test seam, so this passes on dev
        // machines that have the model and on clean CI runners that don't.
        defer { ModelStore.speechModelInstalledOverride = nil }
        ModelStore.speechModelInstalledOverride = false
        XCTAssertFalse(state.canAdvance(from: .onDeviceSetup), "no model, no Continue")
        ModelStore.speechModelInstalledOverride = true
        XCTAssertTrue(state.canAdvance(from: .onDeviceSetup), "ready model unlocks Continue")
    }
}

// MARK: - Progress persistence: quit mid-flow resumes, completion clears

@MainActor
final class OnboardingResumeTests: XCTestCase {
    private func clearSaved() {
        UserDefaults.standard.removeObject(forKey: OnboardingState.savedStepKey)
    }

    func testQuitMidFlowResumesAtTheSavedStep() {
        clearSaved()
        defer { clearSaved() }
        let first = OnboardingState(persistsProgress: true)
        first.step = .cleanup
        let second = OnboardingState(persistsProgress: true)
        XCTAssertEqual(second.step, .cleanup)
    }

    /// Builds before 2026-09-15 saved these raw values with the account steps
    /// at 4–6; an update must resume the same step, not a renumbered one.
    func testAStepSavedByAnOlderBuildResumesTheSameStep() {
        clearSaved()
        defer { clearSaved() }
        for (saved, expected) in [(3, OnboardingState.Step.hotkey), (7, .onDeviceSetup), (8, .cleanup), (9, .done)] {
            UserDefaults.standard.set(saved, forKey: OnboardingState.savedStepKey)
            XCTAssertEqual(OnboardingState(persistsProgress: true).step, expected, "saved raw value \(saved)")
        }
    }

    func testASavedAccountStepStartsOver() {
        clearSaved()
        defer { clearSaved() }
        for removed in [4, 5, 6] {
            UserDefaults.standard.set(removed, forKey: OnboardingState.savedStepKey)
            XCTAssertEqual(OnboardingState(persistsProgress: true).step, .welcome,
                           "raw value \(removed) was a removed account step")
        }
    }

    func testMarkCompleteClearsSavedProgress() {
        clearSaved()
        defer { clearSaved() }
        let state = OnboardingState(persistsProgress: true)
        state.step = .hotkey
        OnboardingState.markComplete()
        XCTAssertEqual(UserDefaults.standard.integer(forKey: OnboardingState.savedStepKey), 0)
        UserDefaults.standard.set(false, forKey: OnboardingState.completedKey)
    }
}
