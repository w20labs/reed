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

    func testFormerTelemetryHostsAreBlocked() {
        // Reed has no telemetry since 2026-09-26: the analytics ingest left
        // the allowlist, and the crash-report ingest was never on it.
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "eu.aptabase.com"))
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "aptabase.com"))
        XCTAssertFalse(GateURLProtocol.isAllowed(host: "o4511827269779456.ingest.de.sentry.io"))
    }
}
