import XCTest
@testable import Reed

/// Pins deep-audit batch 2 (findings 7–9): sealed tokens stop cross-sentence
/// matching, prose verbs stop domain/email joins. (Finding 10 — variant
/// identity in the recognizer client — and the paragraph preservation in
/// LocalCleanup.aiOutcome have no unit seam without a real model load; both
/// were verified by code trace.)
final class AuditBatch2Tests: XCTestCase {

    // MARK: - 7: matches never cross a sealed token

    func testTermMatchNeverCrossesSentenceBoundary() {
        XCTAssertEqual(
            CorrectionPass.apply("I finished the app. Store the files.", active: [.general]).text,
            "I finished the app. Store the files.")
    }

    func testTermMatchStillFiresInsideASentence() {
        XCTAssertEqual(
            CorrectionPass.apply("the app store is down", active: [.general]).text,
            "the App Store is down")
    }

    func testTimeNeverCrossesSentenceBoundary() {
        // "Am" after the period is the verb, not the meridiem.
        XCTAssertEqual(
            CorrectionPass.apply("Pick one. Am I wrong?", active: [.general]).text,
            "Pick one. Am I wrong?")
    }

    func testCurrencyNeverCrossesSentenceBoundary() {
        XCTAssertEqual(
            CorrectionPass.apply("I have five. Dollars are scarce.", active: [.general]).text,
            "I have five. Dollars are scarce.")
    }

    func testCommaSealsMatchesToo() {
        XCTAssertEqual(
            CorrectionPass.apply("Pick one, am I wrong?", active: [.general]).text,
            "Pick one, am I wrong?")
    }

    func testCurrencyStillFormatsInsideASentence() {
        XCTAssertEqual(
            CorrectionPass.apply("it costs five dollars today", active: [.general]).text,
            "it costs $5 today")
    }

    // MARK: - 8: prose verbs stop domain/email joins

    func testFromNeverJoinsIntoDomain() {
        XCTAssertEqual(
            CorrectionPass.apply("download it from example dot com", active: [.general]).text,
            "download it from example.com")
    }

    func testWorksAtFormedDomainIsNotAnEmail() {
        XCTAssertEqual(
            CorrectionPass.apply("she works at acme.ai", active: [.general]).text,
            "she works at acme.ai")
    }

    func testRealEmailStillJoins() {
        XCTAssertEqual(
            CorrectionPass.apply("email jane at example.com", active: [.general]).text,
            "email jane@example.com")
    }
}
