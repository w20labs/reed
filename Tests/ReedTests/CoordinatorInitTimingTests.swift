import XCTest
@testable import Reed

/// Regression tests for the class of bugs where work on the main actor blocks
/// app launch. A 2026-06 Sentry AppHang report (release 0.1.12) traced to
/// `Coordinator.init` doing synchronous `KeyStore.get` → `SecItemCopyMatching`
/// reads, which on first launch waited 2+ s for the macOS Keychain prompt.
/// The fix moved Keychain access off the main actor; these tests guard the
/// budget so a future change can't quietly add main-thread work back.
final class CoordinatorInitTimingTests: XCTestCase {
    @MainActor
    func testInitDoesNotBlockMainThread() {
        // 200 ms is generous; in practice init is microseconds. Anything close
        // to the cap means someone reintroduced a synchronous Keychain, file,
        // or network read in the init body.
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = Coordinator() }
        XCTAssertLessThan(
            elapsed, .milliseconds(200),
            "Coordinator.init blocked the main thread for \(elapsed). " +
            "Move any new sync work into a Task.detached — see the onboarding " +
            "and What's New launch task."
        )
    }
}
