import AVFoundation
import Foundation
import KeyboardShortcuts

/// Drives the first-launch onboarding flow (design/hud-design-system.html →
/// "Onboarding"): welcome → microphone → accessibility → hotkey → speech
/// model → cleanup → done. Owns no UI — `OnboardingView` reads `step` and
/// calls `advance()` / `back()`.
@MainActor
final class OnboardingState: ObservableObject {
    /// Raw values are persisted (`savedStepKey`), so they are pinned: the
    /// removed account steps once sat at 4–6, and renumbering the steps after
    /// them would resume a user who quit mid-flow on the wrong step.
    enum Step: Int, CaseIterable {
        case welcome = 0
        case microphone = 1
        case accessibility = 2
        case hotkey = 3
        case onDeviceSetup = 7  // speech-model download gates Continue
        case cleanup = 8        // the cleanup switch, never blocking
        case done = 9

        var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .done }
    }

    /// Flipped to `true` after the user completes (or dismisses) onboarding.
    /// Stored as a UserDefault so we never re-show it.
    nonisolated static let completedKey = "reed.onboarding.completed"
    /// Progress persistence: quitting mid-onboarding must not reset the flow —
    /// the earlier steps were done once and stay done. Cleared on completion.
    nonisolated static let savedStepKey = "reed.onboarding.step"

    @Published var step: Step = .welcome {
        didSet {
            guard persistsProgress else { return }
            UserDefaults.standard.set(step.rawValue, forKey: Self.savedStepKey)
        }
    }

    /// `persistsProgress` defaults off under XCTest (same class-probe as the
    /// KeyStore shield) so ordinary tests can't leak saved progress into the
    /// real defaults; the resume tests opt in explicitly.
    init(persistsProgress: Bool = NSClassFromString("XCTestCase") == nil) {
        self.persistsProgress = persistsProgress
        restoreProgress()
    }

    private let persistsProgress: Bool

    /// Resume a flow the user quit partway through. A saved value that names
    /// no current step (one of the removed account steps) starts over.
    private func restoreProgress() {
        guard persistsProgress else { return }
        let savedStep = UserDefaults.standard.integer(forKey: Self.savedStepKey)
        if let candidate = Step(rawValue: savedStep) {
            step = candidate
        }
    }

    /// True if this is a brand-new install we should onboard. False if the
    /// user has already completed onboarding. Nonisolated — touches only
    /// UserDefaults.
    nonisolated static func shouldShowOnFirstLaunch() -> Bool {
        // QA override: force onboarding regardless of completion —
        // otherwise a dev machine that's already completed it once can
        // never reach the fresh-install state again.
        // defaults write com.local.reed reed.debugOnboarding -bool YES
        if UserDefaults.standard.bool(forKey: "reed.debugOnboarding") {
            return true
        }
        return !UserDefaults.standard.bool(forKey: completedKey)
    }

    /// The step after `current`, walked by position rather than raw value
    /// (the raw values have a gap).
    func nextStep(after current: Step) -> Step {
        let all = Step.allCases
        return all[min(current.index + 1, all.count - 1)]
    }

    /// True if the user has done what this step asks. Drives the global
    /// "Next" button's enabled state so an information-only step (Welcome,
    /// Done) can always advance, but an action step (mic, accessibility,
    /// model download) keeps Next disabled until the requirement is met.
    /// Re-evaluated on every observed-object change.
    func canAdvance(from current: Step) -> Bool {
        switch current {
        case .welcome, .done:
            return true
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            return TextInjector.ensureAccessibilityPermission(prompt: false)
        case .hotkey:
            // Never blocking: the ⌃⌥ hold is a real default that needs no
            // recorded shortcut, so there is nothing to require here.
            return true
        case .onDeviceSetup:
            // Reed cannot run without the model — Done is only ever reachable
            // with it installed. The progress bar is the wait state.
            //
            // `isSpeechModelReady` means "downloaded AND proven to load"
            // (the loaded record is written only after a successful CoreML
            // load), so this never goes true mid-download the way it did on
            // 2026-08-12 — Continue used to light up over a spinner that
            // never finished. P15 (DECIDED 2026-09-02): the one model is
            // Parakeet v3.
            return ModelStore.isSpeechModelReady && !ModelDownloadController.shared.isDownloading
        case .cleanup:
            // Never blocking: cleanup is a preference, not a requirement.
            // Unlike the model, nothing downstream fails without it — and
            // with Apple Intelligence off (or macOS < 26) it still runs, on
            // the rules pass. The step writes an explicit tier on appear, so
            // arriving and pressing Continue is itself a valid answer.
            return true
        }
    }

    /// Steps to render in the sidebar: every step, in order.
    var visibleSteps: [Step] { Step.allCases }

    /// The step before `current`. A user can always revisit an earlier step
    /// just to look at it.
    func previousStep(before current: Step) -> Step {
        Step.allCases[max(current.index - 1, 0)]
    }

    func advance() {
        step = nextStep(after: step)
    }

    func back() {
        step = previousStep(before: step)
    }

    /// Mark onboarding finished and persist. Called by `Done` step or any
    /// "Skip" button. Idempotent. Nonisolated — touches only UserDefaults.
    nonisolated static func markComplete() {
        UserDefaults.standard.set(true, forKey: completedKey)
        UserDefaults.standard.removeObject(forKey: savedStepKey)
        // Suppress the What's New sheet for fresh installs: the user just
        // saw a welcome experience covering the current feature set, so
        // surfacing a What's New for the same version would be redundant.
        WhatsNew.markSeen()
    }
}
