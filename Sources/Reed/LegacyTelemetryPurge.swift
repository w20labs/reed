import Foundation

/// One-shot removal of what the optional usage analytics (Aptabase) and crash
/// reporting (Sentry) stored on a Mac before Reed dropped telemetry entirely
/// (2026-09-26). Nothing reads these any more.
///
/// Sentry's queued, unsent reports under `~/Library/Caches/io.sentry/` are
/// left alone on purpose: that directory is shared with any other app that
/// uses Sentry, and the per-app subfolder is named by a hash of a key this
/// build no longer has. Without the SDK nothing ever sends them.
enum LegacyTelemetryPurge {
    static let doneKey = "legacyTelemetryPurge.v1"

    static let defaultsKeys = [
        "enableAnalytics",                  // the analytics switch
        "reed.crashReportsDisabled",        // the crash-report switch (stored inverted)
        "firstDictationTransport",          // first-dictation facts, held until sent
        "firstDictationTimeToAudioMs",
        "firstDictationEmitted",
        "reed.telemetryOffMigration.v1",    // the 2026-09-14 switch-off marker
        "telemetryConsentAsked",            // 0.2.x consent card
        "telemetryConsentSuccessCount",
    ]

    static func runOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for key in defaultsKeys { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: doneKey)
    }
}
