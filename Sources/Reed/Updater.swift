import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller so the rest of
/// the app doesn't import Sparkle directly. Configuration (feed URL, public
/// EdDSA key, automatic-check policy) lives in Info.plist; Sparkle reads it
/// at init time.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// nil exactly when running under XCTest — see `init`.
    private let controller: SPUStandardUpdaterController?

    /// True when this process is a test runner. XCTest is linked only into
    /// test binaries, so the class existing is a reliable, production-safe
    /// signal. (`NSApp.isRunning` is NOT: it is also false in the real app
    /// during launch, which would silently disable updates for users.)
    nonisolated static var isRunningUnderXCTest: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Whether Sparkle was actually started. False under XCTest, true in the
    /// app. Exposed so the regression test can pin the guard.
    var isUpdaterActive: Bool { controller != nil }

    private init() {
        // NEVER start Sparkle in a test process. `swift test`'s Bundle.main is
        // Xcode's xctest tool — no SUFeedURL, no EdDSA key, not an app bundle —
        // so SPUStandardUpdaterController fails to start and schedules its
        // "updater error" NSAlert onto the main queue ~1.5 s after process
        // launch (measured twice on CI: 1.48 s and 1.39 s, both stacks ending
        // at the same Sparkle instruction, +0xaf1c). The first test whose
        // invocation pumps the run loop then services that alert; runModal
        // blocks the main thread forever and `swift test` wedges until the CI
        // job timeout kills it. The full suite executes in ~0.95 s on CI, so
        // whether it finishes before the alert lands is a knife-edge race —
        // which is why the hang was intermittent, why it appeared once the
        // suite grew past ~1 s (2026-07-28), and why it never reproduced
        // locally (~0.5 s suite, plus a persisted SUEnableAutomaticChecks=0
        // in this machine's xctest defaults domain from earlier runs).
        //
        // Any test that touches `Updater.shared` would boot Sparkle; guarding
        // at the source covers every such route at once.
        guard !Updater.isRunningUnderXCTest else {
            controller = nil
            return
        }
        // startingUpdater: true → Sparkle schedules background update checks
        // immediately. Frequency comes from SUScheduledCheckInterval in
        // Info.plist (defaults to once per day if absent), gated by
        // SUEnableAutomaticChecks.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Set explicitly, not just defaulted: builds before 2026-07-30
        // persisted `SUEnableAutomaticChecks = 0` into user defaults (their
        // Local Only mode disabled update checks), and Sparkle reads that
        // stored value over the Info.plist. This write migrates those users
        // back.
        controller?.updater.automaticallyChecksForUpdates = true
    }

    /// Manual "Check for Updates…" from the menubar. Pops Sparkle's UI even
    /// when there's no newer version, so users always get feedback.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Whether the menubar item should be enabled (Sparkle disables it while
    /// a check is in flight). Bound from MenuView.
    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }
}
