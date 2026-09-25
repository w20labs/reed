import XCTest
@testable import Reed

/// D3 (2026-09-21): production telemetry identifiers are excluded from public
/// source defaults; official builds supply them at build time, and telemetry
/// stays off until the user opts in.
///
/// The decision only holds if it is checked. The first test here is the one
/// that matters: it reads the *tracked* `Info.plist` and fails if a real
/// identifier is ever committed back, which is exactly how this would regress —
/// someone pastes a DSN in to debug something locally and commits it.
final class TelemetryConfigurationTests: XCTestCase {
    /// The repository root, from this file rather than from a working directory,
    /// so the test reads the same bytes a contributor would clone.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReedTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func trackedInfoPlist() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], "Info.plist is not a dictionary")
    }

    func testTrackedInfoPlistCarriesNoTelemetryIdentifiers() throws {
        let plist = try trackedInfoPlist()
        for key in ["SentryDSN", "AptabaseAppKey"] {
            XCTAssertNotNil(plist[key], "\(key) must stay present so the plist shape is stable")
            XCTAssertNil(
                TelemetryIdentifier.value(plist[key]),
                """
                \(key) carries a value in the tracked Info.plist. Public source \
                ships these empty (D3): build-app.sh injects REED_SENTRY_DSN and \
                REED_APTABASE_APP_KEY into the bundle for official releases. \
                Committing one here points every fork and contributor build at \
                W20's accounts.
                """
            )
        }
    }

    // MARK: - What counts as configured

    func testAbsentEmptyAndBlankAllMeanUnconfigured() {
        XCTAssertNil(TelemetryIdentifier.value(nil))
        XCTAssertNil(TelemetryIdentifier.value(""))
        XCTAssertNil(TelemetryIdentifier.value("   "))
        XCTAssertNil(TelemetryIdentifier.value("\n\t "))
        XCTAssertNil(TelemetryIdentifier.value(42), "a non-string is not an identifier")
    }

    func testARealValueIsConfiguredAndTrimmed() {
        XCTAssertEqual(TelemetryIdentifier.value("A-EU-0000000000"), "A-EU-0000000000")
        XCTAssertEqual(TelemetryIdentifier.value("  A-EU-0000000000\n"), "A-EU-0000000000")
    }

    /// Whitespace is the case that would otherwise look configured, render a
    /// live toggle, and then fail inside the SDK where nobody sees it.
    func testBlankDoesNotLookConfigured() {
        XCTAssertNil(TelemetryIdentifier.value(" "), "a blank value must not enable a toggle")
    }

    // MARK: - The build script injects into the bundle, never into the tree

    private func buildScript() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("build-app.sh"), encoding: .utf8)
    }

    func testBuildScriptInjectsBothIdentifiersFromTheEnvironment() throws {
        let script = try buildScript()
        XCTAssertTrue(script.contains("REED_SENTRY_DSN"), "no injection path for the Sentry DSN")
        XCTAssertTrue(script.contains("REED_APTABASE_APP_KEY"), "no injection path for the Aptabase key")
    }

    /// The injection must only ever touch the bundle's copy. A `PlistBuddy Set`
    /// aimed at the tracked `Info.plist` would write a real identifier into the
    /// working tree, where it could be committed by accident.
    func testInjectionNeverTargetsTheTrackedPlist() throws {
        let script = try buildScript()
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains("PlistBuddy"), line.contains("Set :") else { continue }
            XCTAssertTrue(
                line.contains("$BUNDLE/Contents/Info.plist"),
                "PlistBuddy Set must target the bundle, not the tree: \(line)"
            )
        }
    }

    /// An unconfigured build must say so rather than look like a configured one.
    func testBuildScriptReportsWhenTelemetryIsUnconfigured() throws {
        let script = try buildScript()
        XCTAssertTrue(
            script.contains("telemetry unconfigured"),
            "an unconfigured build should announce that it reports nowhere"
        )
    }

    // MARK: - Opt-in survives the change

    /// D3 changes where identifiers come from, not the consent rule: telemetry
    /// is off until the user turns it on, and Reed never asks.
    func testAnalyticsStillDefaultsOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TelemetryConfigurationTests.defaults"))
        defaults.removePersistentDomain(forName: "TelemetryConfigurationTests.defaults")
        XCTAssertFalse(Analytics.isEnabled(in: defaults), "analytics must default to off")
    }
}
