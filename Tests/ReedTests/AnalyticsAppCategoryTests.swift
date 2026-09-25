import XCTest
@testable import Reed

final class AnalyticsAppCategoryTests: XCTestCase {
    func testKnownBundleIDsMapToExpectedCategories() {
        let cases: [(String, String)] = [
            ("com.apple.Terminal", "terminal"),
            ("com.googlecode.iterm2", "terminal"),
            ("dev.warp.Warp-Stable", "terminal"),
            ("com.apple.dt.Xcode", "ide"),
            ("com.microsoft.VSCode", "ide"),
            ("com.todesktop.230313mzl4w4u92", "ide"), // Cursor
            ("com.tinyspeck.slackmacgap", "chat"),
            ("com.hnc.Discord", "chat"),
            ("com.apple.MobileSMS", "chat"),
            ("com.apple.mail", "email"),
            ("com.microsoft.Outlook", "email"),
            ("com.apple.Safari", "browser"),
            ("com.google.Chrome", "browser"),
            ("com.apple.Notes", "notes_docs"),
            ("notion.id", "notes_docs"),
        ]
        for (bundleID, expected) in cases {
            XCTAssertEqual(Analytics.appCategory(for: bundleID), expected,
                           "expected \(bundleID) to map to \(expected)")
        }
    }

    func testUnmappedRealBundleIDReturnsOther() {
        XCTAssertEqual(Analytics.appCategory(for: "com.example.SomeRandomApp"), "other")
    }

    func testNilBundleIDReturnsUnknown() {
        XCTAssertEqual(Analytics.appCategory(for: nil), "unknown")
    }
}
