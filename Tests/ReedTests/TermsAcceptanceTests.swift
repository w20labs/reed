import XCTest
@testable import Reed

/// Terms acceptance (design P12): version-stamped, idempotent, and versioned
/// so a future material terms change re-arms the notice.
final class TermsAcceptanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: TermsAcceptance.versionKey)
        UserDefaults.standard.removeObject(forKey: TermsAcceptance.dateKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TermsAcceptance.versionKey)
        UserDefaults.standard.removeObject(forKey: TermsAcceptance.dateKey)
        super.tearDown()
    }

    func testRecordStampsVersionAndDate() {
        XCTAssertFalse(TermsAcceptance.isRecorded)
        TermsAcceptance.record()
        XCTAssertTrue(TermsAcceptance.isRecorded)
        XCTAssertEqual(UserDefaults.standard.string(forKey: TermsAcceptance.versionKey),
                       TermsAcceptance.currentVersion)
        let stamp = UserDefaults.standard.string(forKey: TermsAcceptance.dateKey)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: stamp ?? ""),
                        "acceptance time must be a parseable ISO-8601 stamp")
    }

    func testRecordIsIdempotent() {
        TermsAcceptance.record()
        let first = UserDefaults.standard.string(forKey: TermsAcceptance.dateKey)
        TermsAcceptance.record()
        XCTAssertEqual(UserDefaults.standard.string(forKey: TermsAcceptance.dateKey), first,
                       "a second record() must not overwrite the original acceptance time")
    }

    func testOldVersionReArmsTheNotice() {
        UserDefaults.standard.set("2020-01-01", forKey: TermsAcceptance.versionKey)
        XCTAssertFalse(TermsAcceptance.isRecorded,
                       "a stale accepted version is the re-acceptance hook — not recorded")
    }
}
