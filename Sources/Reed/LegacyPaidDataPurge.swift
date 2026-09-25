import Foundation

/// One-shot removal of what the account, cloud and paid features stored on a
/// Mac before Reed became free and fully local (2026-09-15). Nothing reads
/// these any more; they are removed so a free install carries no sign-in
/// token, cached pricing or orphaned hotkeys. One-shot because the Keychain
/// delete can prompt against an item an older build signed (KeyStore).
enum LegacyPaidDataPurge {
    /// v2: the earlier PR build stamped `freeLocalPurge.v1` even after a
    /// refused Keychain delete, and without the plaintext token — an install
    /// carrying v1 is not trusted to be clean.
    static let doneKey = "freeLocalPurge.v2"
    static let staleDoneKeys = ["freeLocalPurge.v1"]

    static let defaultsKeys = [
        "authRefreshToken",         // the sign-in token's plaintext copy (KeyStore's pre-Keychain slot)
        "pipelineMode",             // Cloud / Local Only choice
        "lastSignedInEmail",        // sign-in form prefill
        "reed.pricing",             // cached /api/pricing
        "reed.featureFlags",        // cached /api/flags
        "proInterestSubmitted",     // Reed Pro "Notify me"
        "vocabularyTerms",          // server-side vocabulary list
        "reed.onboarding.path",     // free / managed onboarding path
        // Formatting-mode hotkeys (KeyboardShortcuts stores each name so).
        "KeyboardShortcuts_composeEmail",
        "KeyboardShortcuts_composeSlack",
        "KeyboardShortcuts_composeList",
        "KeyboardShortcuts_composeTask",
        "instantText",              // documented snap-clean kill switch
        // Per-install overrides of the removed features' flags.
        "reed.flagOverride.instant_text",
        "reed.flagOverride.correction_flywheel",
        "reed.flagOverride.vocabulary_injection",
        "reed.flagOverride.voice_task_extraction",
    ]

    /// Done only once the Keychain token is confirmed gone: a refused delete
    /// (e.g. errSecAuthFailed) leaves a credential with no account UI left to
    /// remove it, so the next launch tries again.
    static func runOnce(defaults: UserDefaults = .standard) {
        for stale in staleDoneKeys { defaults.removeObject(forKey: stale) }
        guard !defaults.bool(forKey: doneKey) else { return }
        for key in defaultsKeys { defaults.removeObject(forKey: key) }
        guard KeyStore.delete(account: KeyStore.legacyRefreshTokenAccount) else { return }
        defaults.set(true, forKey: doneKey)
    }
}
