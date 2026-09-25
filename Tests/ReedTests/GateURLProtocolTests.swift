import XCTest
@testable import Reed

/// The host allowlist is suffix-based; a matching slip here is a hole in the
/// network guarantee, so the boundaries are pinned directly.
final class GateURLProtocolTests: XCTestCase {
    func testAllowedHostsAndTheirSubdomains() {
        XCTAssertTrue(GateURLProtocol.isAllowed(host: "huggingface.co"))
        XCTAssertTrue(GateURLProtocol.isAllowed(host: "cdn-lfs.huggingface.co"))
        XCTAssertTrue(GateURLProtocol.isAllowed(host: "cas-bridge.xethub.hf.co"))
    }

    func testReedsFormerBackendIsNotAllowed() {
        // The account and cloud features that talked to it are gone
        // (2026-09-15); nothing in the app may reach it.
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "reed.w20.ai"))
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "api.reed.w20.ai"))
    }

    func testLookalikeHostsAreBlocked() {
        // Suffix matching must require a label boundary…
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "nothuggingface.co"))
        // …and must never match a suffix that sits mid-hostname.
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "huggingface.co.attacker.net"))
        // Unknown third-party hosts stay out.
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "w20.ai"))
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "example-analytics.com"))
    }

    func testOptInAnalyticsHostClearsTheGate() {
        // Operational traffic obeys the Privacy toggles, not the gate. The
        // allowlist was missing the analytics host until 2026-08-06, so
        // opted-in events were silently dropped while Sentry (same consent,
        // own transport) went through. Per-event consent gating still applies
        // above this layer (Analytics.isEnabled, default OFF).
        XCTAssertTrue(GateURLProtocol.isAllowed(host: "eu.aptabase.com"))
        XCTAssertTrue(GateURLProtocol.isAllowed(host: "aptabase.com"))
        // Boundary rule still holds around the suffix.
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "notaptabase.com"))
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "aptabase.com.evil.net"))
    }
}
