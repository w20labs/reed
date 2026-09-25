import XCTest
@testable import Reed

/// Sparkle must never start inside a test process.
///
/// The 2026-07-29 CI hang: a test that touched `Updater.shared` for the first
/// time (then via the sign-out path, since removed) booted Sparkle inside
/// xctest. With no feed URL and
/// no app bundle, Sparkle scheduled its startup-error NSAlert onto the main
/// queue ~1.5 s after launch; the first test invocation to pump the run loop
/// serviced it, `runModal` blocked the main thread forever, and `swift test`
/// wedged until the CI job timeout. The suite runs in ~1 s, so it was a
/// knife-edge race — intermittent on CI, invisible locally.
final class UpdaterTests: XCTestCase {

    func testThisProcessIsRecognisedAsATestRunner() {
        // The guard's entire premise. If this detection ever breaks, the
        // assertions below would pass vacuously in the app and fail to
        // protect CI, so pin it explicitly.
        XCTAssertTrue(Updater.isRunningUnderXCTest)
    }

    /// Touching `Updater.shared` here IS the regression test: before the
    /// guard, this very line booted Sparkle and armed the modal. If someone
    /// removes the guard, this test re-arms the hang — and the CI job
    /// timeout plus the log sampler will name it.
    @MainActor
    func testUpdaterIsInertUnderXCTest() {
        XCTAssertFalse(Updater.shared.isUpdaterActive,
                       "Sparkle must not start in a test process — it schedules a modal error alert that wedges the suite")
        XCTAssertFalse(Updater.shared.canCheckForUpdates)

        // The entry points a test can reach must be safe no-ops, not
        // Sparkle boots.
        Updater.shared.checkForUpdates()
        XCTAssertFalse(Updater.shared.isUpdaterActive)
    }
}
