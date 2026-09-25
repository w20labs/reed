import XCTest
@testable import Reed

/// Pins the engine contract. Since 2026-08-29 (lever 3) a build cut from
/// main recognizes with Parakeet v3 by default; another variant name selects
/// it. There is no other engine: the `off` pin that once meant WhisperKit
/// is an unknown value now (2026-09-06), and an unknown value is v3. The
/// capture lab (UsageLog + engine switcher UI) was removed for release
/// (2026-08-24).
final class EngineLabFlagTests: XCTestCase {
    private var savedParakeet: Any?

    override func setUp() {
        super.setUp()
        savedParakeet = UserDefaults.standard.object(forKey: ParakeetFlag.key)
        UserDefaults.standard.removeObject(forKey: ParakeetFlag.key)
    }

    override func tearDown() {
        if let savedParakeet {
            UserDefaults.standard.set(savedParakeet, forKey: ParakeetFlag.key)
        }
        super.tearDown()
    }

    func testParakeetV3IsTheDefault() {
        XCTAssertEqual(ParakeetFlag.variant, "v3")
        XCTAssertEqual(ParakeetFlag.defaultVariant, "v3")
    }

    func testAnotherVariantSelectsItAndTheRetiredOffPinIsJustUnknown() {
        UserDefaults.standard.set("ctc110m", forKey: ParakeetFlag.key)
        XCTAssertEqual(ParakeetFlag.variant, "ctc110m")
        UserDefaults.standard.set("off", forKey: ParakeetFlag.key)
        XCTAssertEqual(ParakeetFlag.variant, "v3", "no engine is behind `off` any more: Parakeet runs")
        UserDefaults.standard.set("", forKey: ParakeetFlag.key)
        XCTAssertEqual(ParakeetFlag.variant, "v3", "an empty value is the default")
    }

    /// Review 2026-09-01: an unknown name used to load v3 while every log and
    /// bench reported the made-up label. The label must be the model that runs.
    func testUnknownVariantIsTheDefaultModelUnderItsOwnName() {
        for typo in ["v33", "V3", "parakeet", "ctc"] {
            UserDefaults.standard.set(typo, forKey: ParakeetFlag.key)
            XCTAssertEqual(ParakeetFlag.variant, "v3", typo)
        }
        for variant in ParakeetFlag.supportedVariants {
            UserDefaults.standard.set(variant, forKey: ParakeetFlag.key)
            XCTAssertEqual(ParakeetFlag.variant, variant)
        }
        XCTAssertTrue(ParakeetFlag.supportedVariants.contains(ParakeetFlag.defaultVariant))
    }
}
