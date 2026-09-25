import Foundation
import Security

private let klog = Log(category: "keystore")

/// What is left of Reed's Keychain use: removing items earlier builds wrote.
/// Reed stores nothing in the Keychain any more (provider keys went
/// 2026-07-22, the account refresh token 2026-09-15).
enum KeyStore {
    /// The sign-in refresh token builds before 2026-09-15 kept.
    static let legacyRefreshTokenAccount = "authRefreshToken"

    /// User-supplied Groq/Anthropic keys were removed as a tier 2026-07-22.
    /// Purge any keys left behind by earlier builds — Keychain and the
    /// pre-Keychain UserDefaults slots. Safe to call every launch (no-ops fast).
    /// v2: builds from 2026-07-22 stamped `byoKeysPurged.v1` even after a
    /// refused delete, so an install carrying v1 is not trusted to be clean.
    static let byoPurgeDoneKey = "byoKeysPurged.v2"

    static func purgeLegacyBYOKeys(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "byoKeysPurged.v1")
        // One-shot: don't touch the Keychain on every launch — SecItemDelete
        // against items written by an older build can itself prompt. Done
        // only once every key is confirmed gone; a refused delete retries.
        guard !defaults.bool(forKey: byoPurgeDoneKey) else { return }
        var allGone = true
        for legacy in ["groqKey", "anthropicKey"] {
            if !delete(account: legacy) { allGone = false }
            defaults.removeObject(forKey: legacy)
        }
        guard allGone else { return }
        defaults.set(true, forKey: byoPurgeDoneKey)
    }

    // MARK: - Raw Keychain operations
    //
    // We use the legacy macOS Keychain rather than the data protection
    // ("iOS-style") variant. The DP keychain would avoid the per-cdhash
    // access prompt on rebuilds, but it requires the `keychain-access-groups`
    // entitlement — which is a *restricted* entitlement that needs a
    // provisioning profile from Apple. Developer ID Application certs alone
    // can't add it; trying to do so makes AMFI refuse to launch the bundle
    // ("No matching profile found").
    //
    // Trade-off: during local development the prompt re-fires on every
    // rebuild (cdhash changes). End users, who install a notarized binary
    // and don't rebuild, see the prompt once and click "Always Allow".

    private static let service = "com.local.reed"

    // MARK: - Test shield
    //
    // Under XCTest, every Security call targets the developer's REAL login
    // keychain — and each rebuild re-signs the test binary (new cdhash), so
    // macOS re-prompts "xctest wants to use your confidential information"
    // forever. Tests get a process-local in-memory store instead: same
    // semantics, zero Security calls, zero prompts, no state bleeding
    // between the suite and the developer's actual keys.
    // Internal (not private) so the regression test can PROVE the shield is
    // armed. XCTestConfigurationFilePath is an Xcode-runner convention and is
    // NOT set under SwiftPM's `swift test` (verified on this machine) — that
    // gap let the keychain prompt survive the first fix. The class probe works
    // under every runner; the env vars stay as belt-and-braces.
    static let isRunningTests =
        NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] != nil
    /// The in-memory stand-in for the Keychain under tests. Internal so a test
    /// can seed an item an older build would have left behind.
    static var testStore: [String: String] = [:]

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Test seam: the status a Keychain delete reports under tests (nil means
    /// success), so a refused delete can be driven through the real purges.
    static var deleteStatusForTests: OSStatus?

    /// Removes the item. True when it is gone afterwards — deleted now, or
    /// never there; false when the Keychain refused (e.g. errSecAuthFailed),
    /// so a one-shot caller knows to try again on the next launch.
    static func delete(account: String) -> Bool {
        let status: OSStatus
        if isRunningTests {
            status = deleteStatusForTests ?? errSecSuccess
            if status == errSecSuccess { testStore.removeValue(forKey: account) }
        } else {
            status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            klog.error("SecItemDelete failed for \(account): \(status)")
            return false
        }
        return true
    }
}
