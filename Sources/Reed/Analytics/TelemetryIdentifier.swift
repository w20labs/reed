import Foundation

/// The one place that decides whether a telemetry identifier is usable.
///
/// Reed ships `SentryDSN` and `AptabaseAppKey` **empty** in the tracked
/// `Info.plist` (D3, 2026-09-21); `build-app.sh` writes real values into the
/// bundle's copy for official releases, from `REED_SENTRY_DSN` and
/// `REED_APTABASE_APP_KEY`. A build from source therefore reports nowhere, and
/// a fork can point at its own accounts without editing source.
///
/// These are not secrets — both are extractable from any released app, and
/// both vendors treat them as client-side values. Keeping them out of the
/// repository stops every fork and contributor build reporting into W20's
/// accounts, where their events would mix with Reed's own.
///
/// `Analytics` and `Diagnostics` both route through here so the rule cannot
/// drift between them: an absent key, an empty string and a string of nothing
/// but whitespace all mean *unconfigured*. Whitespace matters because a value
/// that survived a careless edit would otherwise look configured, put a live
/// toggle in Settings, and then fail inside the SDK where nobody is watching.
enum TelemetryIdentifier {
    /// The trimmed identifier, or nil when this build has none.
    static func value(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The identifier stored under `key` in `bundle`, or nil when absent or blank.
    static func value(forKey key: String, in bundle: Bundle = .main) -> String? {
        value(bundle.object(forInfoDictionaryKey: key))
    }
}
