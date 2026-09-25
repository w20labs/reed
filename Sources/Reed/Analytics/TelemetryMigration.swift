import Foundation

/// One-time switch-off for installs that turned telemetry on under the old
/// pre-checked onboarding checkbox or the fifth-win consent card (decided
/// 2026-09-14: every install starts from off, and only Settings → Privacy
/// turns it back on). Runs before `Diagnostics.start()` so Sentry never
/// starts on the migrating launch, and runs once, so a later yes in Settings
/// is kept.
enum TelemetryMigration {
    static let doneKey = "reed.telemetryOffMigration.v1"

    static func runOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        // Removed rather than written false: both stores read an absent value
        // as off (Analytics.isEnabled, Diagnostics.isEnabled).
        defaults.removeObject(forKey: "enableAnalytics")
        defaults.removeObject(forKey: Diagnostics.optOutKey)
        defaults.set(true, forKey: doneKey)
    }
}
