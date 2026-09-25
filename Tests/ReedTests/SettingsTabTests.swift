import XCTest
@testable import Reed

/// Settings shows the same five tabs to everyone: there is no account, no
/// subscription, no Cloud / Local Only choice and no Reed Pro pane
/// (removed 2026-09-15).
final class SettingsTabTests: XCTestCase {
    func testSettingsHasOnlyTheLocalTabs() {
        XCTAssertEqual(SettingsTab.allCases, [.dictation, .cleanup, .permissions, .privacy, .about])
    }

    func testNoTabIsNamedAfterARemovedFeature() {
        let titles = SettingsTab.allCases.map(\.title)
        for removed in ["Account", "Subscription", "Transcription", "Formatting", "Reed Pro"] {
            XCTAssertFalse(titles.contains(removed), "\(removed) must not come back as a tab")
        }
    }
}
