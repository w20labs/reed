import Security
import XCTest
@testable import Reed

/// Regression: the Keychain test-shield MUST be armed under every test runner.
/// The first version keyed on XCTestConfigurationFilePath, which SwiftPM's
/// `swift test` doesn't set — so the "xctest wants to use your confidential
/// information" prompt survived. If this test ever fails, tests are touching
/// the developer's real login keychain again.
final class KeyStoreShieldTests: XCTestCase {
    override func tearDown() {
        KeyStore.deleteStatusForTests = nil
        super.tearDown()
    }

    func testShieldIsArmedUnderThisRunner() {
        XCTAssertTrue(KeyStore.isRunningTests,
                      "test-run detection failed — Keychain prompts will return")
    }

    func testDeleteStaysInMemory() {
        // With the shield armed this exercises only the in-memory store (no
        // Security calls, no prompts).
        KeyStore.testStore["shield-probe"] = "value"
        XCTAssertTrue(KeyStore.delete(account: "shield-probe"))
        XCTAssertNil(KeyStore.testStore["shield-probe"])
    }

    func testDeleteReportsARefusalAndAnAbsentItemAsGone() {
        KeyStore.testStore["shield-probe"] = "value"
        KeyStore.deleteStatusForTests = errSecAuthFailed
        XCTAssertFalse(KeyStore.delete(account: "shield-probe"), "a refused delete is not a deletion")
        XCTAssertEqual(KeyStore.testStore["shield-probe"], "value")
        KeyStore.deleteStatusForTests = errSecItemNotFound
        XCTAssertTrue(KeyStore.delete(account: "shield-probe"), "already absent counts as gone")
        KeyStore.testStore["shield-probe"] = nil
    }
}

/// What the account, cloud and paid features left on a Mac is removed, and a
/// cleanup that could not finish tries again on the next launch.
final class LegacyPaidDataPurgeTests: XCTestCase {
    /// Every place builds before 2026-09-15 stored data for the removed
    /// features, taken from those builds' sources — deliberately NOT read from
    /// `LegacyPaidDataPurge.defaultsKeys`, so a key missing there fails here.
    private static let oldDefaultsInventory = [
        "authRefreshToken",            // KeyStore.migrateFromUserDefaults: the plaintext token
        "pipelineMode",                // PipelineMode.defaultsKey
        "lastSignedInEmail",           // RememberedEmail.defaultsKey
        "reed.pricing",                // ReedPricing.cacheKey
        "proInterestSubmitted",        // SettingsView+ProPane @AppStorage
        "vocabularyTerms",             // VocabularyStore.key
        "reed.featureFlags",           // FeatureFlags.cacheKey
        "reed.onboarding.path",        // OnboardingState.savedPathKey
        "KeyboardShortcuts_composeEmail", "KeyboardShortcuts_composeSlack",   // Shortcut.swift names,
        "KeyboardShortcuts_composeList", "KeyboardShortcuts_composeTask",     // KeyboardShortcuts prefix
        "instantText",                 // documented kill switch (Coordinator+Pipeline)
        "reed.flagOverride.instant_text", "reed.flagOverride.correction_flywheel",
        "reed.flagOverride.vocabulary_injection", "reed.flagOverride.voice_task_extraction",
    ]

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "reed.tests.legacyPurge.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        KeyStore.deleteStatusForTests = nil
        KeyStore.testStore[KeyStore.legacyRefreshTokenAccount] = nil
        super.tearDown()
    }

    func testRemovesEverythingOldBuildsStored() {
        let defaults = freshDefaults()
        for key in Self.oldDefaultsInventory { defaults.set("old", forKey: key) }
        KeyStore.testStore[KeyStore.legacyRefreshTokenAccount] = "token"

        LegacyPaidDataPurge.runOnce(defaults: defaults)

        for key in Self.oldDefaultsInventory {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must be gone")
        }
        XCTAssertNil(KeyStore.testStore[KeyStore.legacyRefreshTokenAccount], "the Keychain token must be gone")
        XCTAssertTrue(defaults.bool(forKey: LegacyPaidDataPurge.doneKey))
    }

    func testARefusedKeychainDeleteIsRetriedOnTheNextLaunch() {
        let defaults = freshDefaults()
        KeyStore.testStore[KeyStore.legacyRefreshTokenAccount] = "token"
        KeyStore.deleteStatusForTests = errSecAuthFailed

        LegacyPaidDataPurge.runOnce(defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: LegacyPaidDataPurge.doneKey),
                       "the cleanup must not count as done while the credential is still there")
        XCTAssertEqual(KeyStore.testStore[KeyStore.legacyRefreshTokenAccount], "token")

        KeyStore.deleteStatusForTests = nil   // next launch, the Keychain cooperates
        LegacyPaidDataPurge.runOnce(defaults: defaults)
        XCTAssertNil(KeyStore.testStore[KeyStore.legacyRefreshTokenAccount], "the retry removes it")
        XCTAssertTrue(defaults.bool(forKey: LegacyPaidDataPurge.doneKey))
    }

    func testAnAbsentTokenCompletesTheCleanup() {
        let defaults = freshDefaults()
        KeyStore.deleteStatusForTests = errSecItemNotFound
        LegacyPaidDataPurge.runOnce(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: LegacyPaidDataPurge.doneKey))
    }

    /// The PR build before the retry fix stamped `freeLocalPurge.v1` even when
    /// the delete was refused and never removed the plaintext token. An install
    /// carrying that marker must still get the corrected cleanup.
    func testAnInstallMarkedDoneByTheEarlierBuildStillCleansUp() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "freeLocalPurge.v1")
        defaults.set("plaintext", forKey: "authRefreshToken")
        KeyStore.testStore[KeyStore.legacyRefreshTokenAccount] = "token"

        LegacyPaidDataPurge.runOnce(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "authRefreshToken"), "the plaintext token the earlier build missed")
        XCTAssertNil(KeyStore.testStore[KeyStore.legacyRefreshTokenAccount], "the Keychain token it may have failed to delete")
        XCTAssertTrue(defaults.bool(forKey: LegacyPaidDataPurge.doneKey))
        XCTAssertNil(defaults.object(forKey: "freeLocalPurge.v1"), "the stale marker is cleared")
    }

    func testRunsOnceAfterSuccess() {
        let defaults = freshDefaults()
        LegacyPaidDataPurge.runOnce(defaults: defaults)
        defaults.set("new", forKey: "pipelineMode")
        LegacyPaidDataPurge.runOnce(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "pipelineMode"), "new", "a later launch touches nothing")
    }
}

/// The same one-shot rule for the older provider-key purge (2026-07-22).
final class LegacyBYOKeyPurgeTests: XCTestCase {
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "reed.tests.byoPurge.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        KeyStore.deleteStatusForTests = nil
        KeyStore.testStore["groqKey"] = nil
        KeyStore.testStore["anthropicKey"] = nil
        super.tearDown()
    }

    /// Every build since 2026-07-22 stamped `byoKeysPurged.v1` even when a
    /// delete was refused. An install carrying that marker must still get the
    /// corrected purge.
    func testAnInstallMarkedDoneByEarlierBuildsStillPurges() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "byoKeysPurged.v1")
        KeyStore.testStore["groqKey"] = "gsk"
        defaults.set("sk-ant", forKey: "anthropicKey")

        KeyStore.purgeLegacyBYOKeys(defaults: defaults)

        XCTAssertNil(KeyStore.testStore["groqKey"], "the key an earlier refused delete left behind")
        XCTAssertNil(defaults.object(forKey: "anthropicKey"))
        XCTAssertTrue(defaults.bool(forKey: KeyStore.byoPurgeDoneKey))
        XCTAssertNil(defaults.object(forKey: "byoKeysPurged.v1"), "the stale marker is cleared")
    }

    func testARefusedDeleteIsRetriedOnTheNextLaunch() {
        let defaults = freshDefaults()
        KeyStore.testStore["groqKey"] = "gsk"
        KeyStore.deleteStatusForTests = errSecAuthFailed

        KeyStore.purgeLegacyBYOKeys(defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: KeyStore.byoPurgeDoneKey), "not done while a key is still there")

        KeyStore.deleteStatusForTests = nil
        KeyStore.purgeLegacyBYOKeys(defaults: defaults)
        XCTAssertNil(KeyStore.testStore["groqKey"])
        XCTAssertTrue(defaults.bool(forKey: KeyStore.byoPurgeDoneKey))
    }
}
