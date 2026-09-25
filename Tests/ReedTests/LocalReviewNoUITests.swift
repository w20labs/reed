import XCTest
@testable import Reed

/// P16: the shipped app carries no control and no string for the review
/// copy. It is a developer's tool, switched by the QA tooling's key.
final class LocalReviewNoUITests: XCTestCase {
    func testTheKeyIsOffUnlessSomethingWroteIt() {
        let defaults = UserDefaults(suiteName: "LocalReviewNoUITests-\(UUID().uuidString)")!
        XCTAssertFalse(LocalReviewFlag.isEnabled(in: defaults))
        defaults.set(true, forKey: LocalReviewFlag.key)
        XCTAssertTrue(LocalReviewFlag.isEnabled(in: defaults))
        XCTAssertEqual(LocalReviewFlag.key, "reed.localReview", "the QA tooling writes this exact key")
    }

    func testNoSettingsTabExistsForIt() {
        XCTAssertFalse(SettingsTab.allCases.contains { $0.rawValue.lowercased().contains("review") })
    }

    /// The UI sources (Settings panes, menu, onboarding, HUD) must not name
    /// the feature: no row, no toggle, no footer. Scans the source tree, so
    /// the only way to add such a string is to change this test.
    func testNoUISourceNamesReviewCopies() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Reed")
        // Every directory that draws something a user can see.
        let uiDirs = ["Settings", "Onboarding", "Overlay", "WhatsNew", "UpdateRequired", "Support", "Account", "Modes", "Branding"]
        var offenders: [String] = []
        var scanned = 0
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.path.replacingOccurrences(of: sources.path + "/", with: "")
            let isUI = uiDirs.contains { path.hasPrefix($0 + "/") } || path.hasPrefix("Menu")
            guard isUI else { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8).lowercased()
            for needle in ["review cop", "local review", "localreview", "reviewrecord", "dictationreview"] where text.contains(needle) {
                offenders.append("\(path): \(needle)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "UI sources name the review copy: \(offenders)")
        XCTAssertGreaterThan(scanned, 30, "the scan must cover the UI sources, not an empty set (\(scanned) files)")
    }

    func testTheCollectorStoresNothingWhenTheKeyIsAbsent() {
        let review = DictationReview(keepsContent: false)
        review.segment(0, boundary: .tail, raw: "secret words", corrected: "secret words")
        review.chunkStarted(input: "secret words", repairHint: nil)
        review.attempt(.init(kind: .generic, proposal: "Secret words.", verdict: "accepted", seconds: 0.1))
        review.chunkDelivered("Secret words.", outcome: .modelAccepted, reason: nil)
        let record = review.finish(.init(injection: .init(text: "Secret words.", target: "com.apple.Mail", method: "ax"),
                                         timings: .init(totalSeconds: 0.2), mode: "localOnly", engine: "parakeet"))
        let json = String(decoding: try! JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("secret"), "no text may survive without the key")
        XCTAssertFalse(json.contains("com.apple.Mail"))
    }
}
