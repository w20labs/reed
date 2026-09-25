import XCTest
@testable import Reed

/// Telemetry is opt-in and never asked for (decided 2026-09-14): analytics and
/// crash reports are off on a fresh install, and only the Settings → Privacy
/// toggles turn them on. No onboarding checkbox, no consent card.
final class TelemetryDefaultsTests: XCTestCase {

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "reed.tests.telemetry.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - the defaults ARE the policy

    func testAnalyticsDefaultsOff() {
        // A fresh install sends nothing. If this test fails, the published
        // "what we collect" page is false.
        XCTAssertFalse(Analytics.isEnabled(in: freshDefaults()))
    }

    func testCrashReportsDefaultOff() {
        XCTAssertFalse(Diagnostics.isEnabled(in: freshDefaults()))
    }

    func testAnExplicitYesIsHonored() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "enableAnalytics")
        XCTAssertTrue(Analytics.isEnabled(in: defaults))
        defaults.set(false, forKey: Diagnostics.optOutKey)
        XCTAssertTrue(Diagnostics.isEnabled(in: defaults))
    }

    func testAnExplicitNoIsHonored() {
        // A user who explicitly opted out must stay out.
        let defaults = freshDefaults()
        defaults.set(false, forKey: "enableAnalytics")
        XCTAssertFalse(Analytics.isEnabled(in: defaults))
        defaults.set(true, forKey: Diagnostics.optOutKey)
        XCTAssertFalse(Diagnostics.isEnabled(in: defaults))
    }

    // MARK: - existing installs are switched off once

    func testMigrationSwitchesAPreviousYesOff() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "enableAnalytics")
        defaults.set(false, forKey: Diagnostics.optOutKey)
        TelemetryMigration.runOnce(defaults: defaults)
        XCTAssertFalse(Analytics.isEnabled(in: defaults), "an install that said yes before 2026-09-14 starts from off")
        XCTAssertFalse(Diagnostics.isEnabled(in: defaults))
    }

    func testMigrationRunsOnceSoALaterYesInSettingsIsKept() {
        let defaults = freshDefaults()
        TelemetryMigration.runOnce(defaults: defaults)
        // The user turns both back on in Settings → Privacy, then relaunches.
        defaults.set(true, forKey: "enableAnalytics")
        defaults.set(false, forKey: Diagnostics.optOutKey)
        TelemetryMigration.runOnce(defaults: defaults)
        XCTAssertTrue(Analytics.isEnabled(in: defaults), "the second launch must not undo a fresh yes")
        XCTAssertTrue(Diagnostics.isEnabled(in: defaults))
    }

    func testMigrationOnAFreshInstallLeavesItOffAndMarksDone() {
        let defaults = freshDefaults()
        TelemetryMigration.runOnce(defaults: defaults)
        XCTAssertFalse(Analytics.isEnabled(in: defaults))
        XCTAssertFalse(Diagnostics.isEnabled(in: defaults))
        XCTAssertTrue(defaults.bool(forKey: TelemetryMigration.doneKey))
    }

    // MARK: - nothing but Settings turns it on

    /// The class this guards: a code path other than the Settings toggles
    /// switching telemetry on. The removed Done-step checkbox and fifth-win
    /// consent card both did, by writing these same two stores.
    func testOnlySettingsTurnsTelemetryOn() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/Reed", directoryHint: .isDirectory)
        // Each way code can WRITE a store (reads are fine), as a regex, and
        // the only files allowed to: the Settings toggles, plus Diagnostics'
        // own setter that the crash-report toggle calls.
        let enablers: [(pattern: String, allowedIn: Set<String>)] = [
            (#"\.set\([^\n]*forKey: "enableAnalytics""#, []),
            (#"\.set\([^\n]*forKey: (Diagnostics\.)?optOutKey"#, ["Diagnostics.swift"]),
            (#"\$enableAnalytics"#, ["SettingsView+Panes.swift"]),
            (#"Diagnostics\.setEnabled\("#, ["SettingsView+Panes.swift"]),
        ]

        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "scanned \(files.count) files under \(sources.path): the scan must not pass by reading nothing")

        var settingsHits = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for enabler in enablers where text.range(of: enabler.pattern, options: .regularExpression) != nil {
                if enabler.allowedIn.contains(file.lastPathComponent) {
                    settingsHits += 1
                } else {
                    XCTFail("\(file.lastPathComponent) contains \(enabler.pattern): only Settings → Privacy may turn telemetry on")
                }
            }
        }
        XCTAssertEqual(settingsHits, 3, "the Settings toggles and Diagnostics' setter must still be found, or the patterns went stale")
    }
}
