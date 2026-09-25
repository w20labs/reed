import XCTest
@testable import Reed

/// Flags are local only: a per-install override, else the caller's default.
final class FeatureFlagsTests: XCTestCase {
    private let testFlag = "reed.tests.neverARealFlag"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FeatureFlags.overrideKey(for: testFlag))
        super.tearDown()
    }

    @MainActor
    func testLocalOverrideWinsWhenDefaultIsFalse() {
        UserDefaults.standard.set(true, forKey: FeatureFlags.overrideKey(for: testFlag))
        XCTAssertTrue(FeatureFlags.shared.isEnabled(testFlag, default: false))
    }

    @MainActor
    func testLocalOverrideCanForceFalseEvenWhenDefaultIsTrue() {
        UserDefaults.standard.set(false, forKey: FeatureFlags.overrideKey(for: testFlag))
        XCTAssertFalse(FeatureFlags.shared.isEnabled(testFlag, default: true))
    }

    @MainActor
    func testFallsBackToCallerDefaultWhenNoOverride() {
        XCTAssertTrue(FeatureFlags.shared.isEnabled(testFlag, default: true))
        XCTAssertFalse(FeatureFlags.shared.isEnabled(testFlag, default: false))
    }

    @MainActor
    func testAValueCachedByAnOldServerFetchIsIgnored() {
        // Builds before 2026-09-15 cached /api/flags here; nothing reads it now.
        let cacheKey = "reed.featureFlags"
        let saved = UserDefaults.standard.object(forKey: cacheKey)
        defer { UserDefaults.standard.set(saved, forKey: cacheKey) }
        UserDefaults.standard.set([testFlag: true], forKey: cacheKey)
        XCTAssertFalse(FeatureFlags.shared.isEnabled(testFlag, default: false))
    }
}
