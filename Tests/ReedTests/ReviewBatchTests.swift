import KeyboardShortcuts
import XCTest
@testable import Reed

/// Pins the 2026-08-25 external-review batch: the release-bucket allowlist
/// hole and the shortcut system-reserve guard. (The re-press race, the
/// in-memory token fallback, and the script fixes have no unit seam.)
final class ReviewBatchTests: XCTestCase {

    func testReleaseBucketClearsTheGate() {
        // The Sparkle appcast lives on Reed's S3 bucket — the gate once
        // silently refused the host (2026-08-25).
        XCTAssertTrue(GateURLProtocol.isAllowed(
            host: "reed-public-551270927645.s3.us-west-2.amazonaws.com"))
    }

    func testAmazonAtLargeIsStillRefused() {
        // Only Reed's own bucket — not S3, not AWS generally.
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "s3.us-west-2.amazonaws.com"))
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "evil.amazonaws.com"))
        XCTAssertFalse(GateURLProtocol.isAllowed(
            host: "reed-public-551270927645.s3.us-west-2.amazonaws.com.evil.com"))
    }

    func testOrdinaryComboIsNotSystemReserved() {
        // The default-adjacent push-to-talk combo must always pass; a positive
        // reserved-combo assert would depend on the machine's own settings.
        XCTAssertFalse(HotkeyRecorderField.isSystemReserved(
            KeyboardShortcuts.Shortcut(.d, modifiers: [.control, .option])))
    }
}
