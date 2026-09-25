import XCTest
@testable import Reed

/// Permanent PR #322 review regressions: identical fixtures through the
/// rules pass and accepted-model post-pass, plus real pause assembly.
/// No recording, injection or real model calls. Included in swift test and
/// the QA Text pipeline row; the model-loop check needs macOS 26 availability.
@MainActor
final class CleanupReviewRegressionTests: XCTestCase {
    private func check(_ cases: [CleanupReviewCases.TextCase], file: StaticString = #filePath, line: UInt = #line) {
        for item in cases {
            let context = "\(item.name): \(item.input)"
            XCTAssertEqual(RestartLicence.collapse(item.input), item.expected, context, file: file, line: line)
            XCTAssertEqual(BasicCleanup.clean(item.input), item.expected, context, file: file, line: line)
        }
    }

    func testPlainRestartsStillCollapse() {
        check(CleanupReviewCases.restarts)
    }

    func testSingleWordsLongerEmphasisAndChainsStaySpoken() {
        check(CleanupReviewCases.repetitions)
    }

    func testBothCopiesRespectSentencesAndTheNegationGate() {
        check(CleanupReviewCases.sentences)
    }

    func testDelimitersSurviveAtEveryPositionInTheAbandonedSpan() {
        check(CleanupReviewCases.delimiters)
    }

    func testQuotedInstructionsAndNestedQuotesAreNotRestarts() {
        check(CleanupReviewCases.quotations)
    }

    func testParagraphsSurviveAndSeparateCopies() {
        check(CleanupReviewCases.paragraphs)
    }

    func testPhraseLengthAndOneCollapsePerPassStayBounded() {
        // Basic also removes the filler; the licence itself deliberately does not.
        for item in CleanupReviewCases.bounded {
            XCTAssertEqual(BasicCleanup.clean(item.input), item.expected, item.name)
        }
    }

    private func assemble(_ cases: [CleanupReviewCases.SeamCase], file: StaticString = #filePath, line: UInt = #line) async {
        for item in cases {
            let context = "\(item.name): \(item.head) | \(item.next)"
            let seam = RestartLicence.crossSeamRestart(head: item.head, next: item.next)
            if item.decision == .restartCollapsed {
                XCTAssertEqual(seam?.joined, item.expected, context, file: file, line: line)
            } else {
                XCTAssertNil(seam, context, file: file, line: line)
            }
            let pieces = [Coordinator.Piece(text: item.head, sealedBy: .pause), .init(text: item.next, sealedBy: nil)]
            var decisions: [Int: ReviewRecord.JoinDecision] = [:]
            let result = await Coordinator.assembleSegments(pieces) { decisions[$0] = $1 }
            XCTAssertEqual(result, item.expected, context, file: file, line: line)
            XCTAssertEqual(decisions, [1: item.decision], context, file: file, line: line)
            let unobserved = await Coordinator.assembleSegments(pieces)
            XCTAssertEqual(unobserved, item.expected, "without observer: \(context)", file: file, line: line)
        }
    }

    func testPauseRestartsPreserveCaseQuotesAndParagraphs() async {
        await assemble(CleanupReviewCases.joined)
    }

    func testPauseNonRestartsKeepContentAndReportTheirActualJoin() async {
        await assemble(CleanupReviewCases.refused)
    }

    func testAcceptedModelPostPassRetainsTheSameReviewCases() async throws {
        guard #available(macOS 26.0, *), AICleanup.isAvailable else {
            throw XCTSkip("model-loop routing requires macOS 26 with Apple Intelligence; model calls are stubbed")
        }
        let savedTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let savedOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = savedOverride
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        LocalCleanup.modelCallOverrideForTests = { text, _ in .text(text) }
        for item in CleanupReviewCases.all {
            let result = await LocalCleanup.applyWithPath(to: item.input)
            XCTAssertEqual(result.path, .ai, "\(item.name): the accepted-model path must actually run")
            XCTAssertEqual(result.text, item.modelExpected, "\(item.name): \(item.input)")
        }
    }
}
