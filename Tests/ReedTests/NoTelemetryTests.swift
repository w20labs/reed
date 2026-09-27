import XCTest
@testable import Reed

/// Reed has no telemetry (2026-09-26). These fail if a telemetry SDK or its
/// configuration comes back, and pin the one-shot cleanup of what the old
/// switches left behind on a Mac.
final class NoTelemetryTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReedTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8).lowercased()
    }

    func testNoTelemetryPackageIsDeclaredOrResolved() throws {
        for file in ["Package.swift", "Package.resolved"] {
            let text = try read(file)
            for sdk in ["aptabase", "sentry"] {
                XCTAssertFalse(text.contains(sdk), "\(file) must not bring back \(sdk)")
            }
        }
    }

    func testInfoPlistCarriesNoTelemetryKeys() throws {
        let plist = try read("Info.plist")
        XCTAssertFalse(plist.contains("aptabaseappkey"))
        XCTAssertFalse(plist.contains("sentrydsn"))
    }

    // MARK: - LegacyTelemetryPurge

    private func freshDefaults() -> UserDefaults {
        let name = "NoTelemetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testThePurgeRemovesEveryOldTelemetryKeyOnce() {
        let defaults = freshDefaults()
        for key in LegacyTelemetryPurge.defaultsKeys { defaults.set(true, forKey: key) }
        defaults.set("kept", forKey: "unrelatedSetting")

        LegacyTelemetryPurge.runOnce(defaults: defaults)

        for key in LegacyTelemetryPurge.defaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must be removed")
        }
        XCTAssertEqual(defaults.string(forKey: "unrelatedSetting"), "kept", "nothing else is touched")
        XCTAssertTrue(defaults.bool(forKey: LegacyTelemetryPurge.doneKey))

        // One-shot: a key set after the purge ran is not the purge's business.
        defaults.set(true, forKey: "enableAnalytics")
        LegacyTelemetryPurge.runOnce(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: "enableAnalytics"))
    }

    func testThePurgeCoversTheSwitchesEveryReleaseUsed() {
        // The analytics switch, the crash-report switch (stored inverted) and
        // 0.2.x's consent card: a key missing here would be left behind.
        for key in ["enableAnalytics", "reed.crashReportsDisabled", "telemetryConsentAsked"] {
            XCTAssertTrue(LegacyTelemetryPurge.defaultsKeys.contains(key), key)
        }
    }
}
