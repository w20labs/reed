import AppKit
import XCTest
@testable import Reed

/// The menu's recent dictations (P18, decided 2026-10-14): the last five,
/// newest first, in memory only; each entry names the app Reed targeted when
/// it attempted the insertion, and a failed paste is kept.
final class RecentDictationsTests: XCTestCase {
    func testKeepsTheLastFiveNewestFirst() {
        var recent = RecentDictations()
        for index in 1...7 { recent.record("dictation \(index)", appName: nil) }
        XCTAssertEqual(recent.entries.map(\.text), ["dictation 7", "dictation 6", "dictation 5", "dictation 4", "dictation 3"])
        XCTAssertEqual(recent.newest?.text, "dictation 7")
        XCTAssertEqual(recent.earlier.count, 4)
    }

    func testTextWithNothingInItIsNotADictation() {
        var recent = RecentDictations()
        recent.record("", appName: "Notes")
        recent.record(" \n\t", appName: "Notes")
        XCTAssertTrue(recent.entries.isEmpty)
    }

    func testTheCompleteTextIsKeptWhateverThePreviewShows() {
        let long = String(repeating: "a long dictation that runs on ", count: 40)
        var recent = RecentDictations()
        recent.record(long, appName: nil)
        XCTAssertEqual(recent.newest?.text, long)
    }

    func testClearEmptiesTheList() {
        var recent = RecentDictations()
        recent.record("one", appName: nil)
        recent.record("two", appName: nil)
        recent.clear()
        XCTAssertNil(recent.newest)
        XCTAssertTrue(recent.earlier.isEmpty)
    }

    func testAgeLabels() {
        let now = Date()
        XCTAssertEqual(RecentDictations.age(of: now.addingTimeInterval(-5), now: now), "just now")
        XCTAssertEqual(RecentDictations.age(of: now.addingTimeInterval(-59), now: now), "just now")
        XCTAssertEqual(RecentDictations.age(of: now.addingTimeInterval(-60), now: now), "1 min")
        XCTAssertEqual(RecentDictations.age(of: now.addingTimeInterval(-4 * 60 - 30), now: now), "4 min")
        XCTAssertEqual(RecentDictations.age(of: now.addingTimeInterval(-3600), now: now), "1 hr")
        XCTAssertEqual(RecentDictations.age(of: now.addingTimeInterval(-2 * 86_400), now: now), "2 d")
        // A clock that stepped backwards never shows a negative age.
        XCTAssertEqual(RecentDictations.age(of: now.addingTimeInterval(120), now: now), "just now")
    }

    func testMetaShowsTheAppWhenKnownAndTimeOnlyOtherwise() {
        let now = Date()
        var recent = RecentDictations()
        recent.record("to slack", appName: "Slack", at: now.addingTimeInterval(-240))
        recent.record("to nowhere", appName: nil, at: now)
        XCTAssertEqual(RecentDictations.meta(recent.entries[1], now: now), "4 min · Slack")
        XCTAssertEqual(RecentDictations.meta(recent.entries[0], now: now), "just now")
    }

    func testAppNameResolvesARunningAppAndNothingForNoTarget() {
        XCTAssertEqual(RecentDictations.appName(forBundleID: "com.apple.finder"), "Finder")
        XCTAssertNil(RecentDictations.appName(forBundleID: nil))
        XCTAssertNil(RecentDictations.appName(forBundleID: ""))
        XCTAssertNil(RecentDictations.appName(forBundleID: "com.example.not-installed-anywhere"))
    }
}

/// The production path both pipelines take: `injectAndRecord`.
@MainActor
final class RecentDictationsRecordingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey)
        super.tearDown()
    }

    func testTheTargetComesFromTheInsertionReceipt() {
        let coordinator = Coordinator()
        coordinator.injectForTesting = { .init(text: $0, target: "com.apple.finder", method: "ax") }

        let receipt = coordinator.injectAndRecord("hello there")

        XCTAssertEqual(receipt.target, "com.apple.finder")
        XCTAssertEqual(coordinator.recentDictations.newest?.text, "hello there")
        XCTAssertEqual(coordinator.recentDictations.newest?.appName, "Finder")
    }

    /// The paste fell back with Accessibility untrusted: it never landed,
    /// which is exactly the dictation the list exists to recover.
    func testAFailedPasteIsStillKept() {
        let coordinator = Coordinator()
        coordinator.injectForTesting = { .init(text: $0, target: nil, method: "paste-untrusted") }

        _ = coordinator.injectAndRecord("the paste that went astray")

        XCTAssertEqual(coordinator.recentDictations.newest?.text, "the paste that went astray")
        XCTAssertNil(coordinator.recentDictations.newest?.appName)
    }

    func testEachDictationIsAddedNewestFirst() {
        let coordinator = Coordinator()
        coordinator.injectForTesting = { .init(text: $0, target: nil, method: "ax") }
        _ = coordinator.injectAndRecord("first")
        _ = coordinator.injectAndRecord("second")
        XCTAssertEqual(coordinator.recentDictations.entries.map(\.text), ["second", "first"])
    }
}
