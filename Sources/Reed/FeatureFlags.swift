import Foundation

/// On/off switches for local features, each with its built-in default at the
/// call site. There is no server: Reed stopped fetching `/api/flags` when it
/// became free and fully local (2026-09-15). A single install can still flip
/// one for development:
///   defaults write com.local.reed reed.flagOverride.<key> -bool YES
@MainActor
final class FeatureFlags {
    static let shared = FeatureFlags()

    private init() {}

    func isEnabled(_ key: String, default fallback: Bool = false) -> Bool {
        if let local = UserDefaults.standard.object(forKey: Self.overrideKey(for: key)) as? Bool {
            return local
        }
        return fallback
    }

    /// Compose the override key for a given feature flag. Public so tests
    /// don't have to duplicate the prefix.
    nonisolated static func overrideKey(for flag: String) -> String {
        "reed.flagOverride.\(flag)"
    }
}
