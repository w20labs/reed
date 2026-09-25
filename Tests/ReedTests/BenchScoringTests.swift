import XCTest
@testable import Reed

/// BenchScoring must reproduce the analyzer scripts exactly — these values
/// were computed with scripts/asr_wer.py and scripts/analyze_p1.py's `pct`.
final class BenchScoringTests: XCTestCase {
    // MARK: percentile — linear interpolation, the scripts' formula

    func testPercentileInterpolatesLikeTheScripts() {
        let hundred = Array(1...100)
        XCTAssertEqual(BenchScoring.percentile(hundred, 0.95) ?? -1, 95.05, accuracy: 1e-9)  // numpy: 95.05
        XCTAssertEqual(BenchScoring.percentile(hundred, 0.5) ?? -1, 50.5, accuracy: 1e-9)
        XCTAssertEqual(BenchScoring.percentile([7], 0.95), 7)
        XCTAssertEqual(BenchScoring.percentile([10, 20], 0.95) ?? -1, 19.5, accuracy: 1e-9)
        XCTAssertEqual(BenchScoring.percentile([3, 1, 2], 1.0), 3)
        XCTAssertEqual(BenchScoring.percentile([3, 1, 2], 0.0), 1)
    }

    /// The review's case: nearest-rank passed a 2000 ms ceiling at 1990 while
    /// the page, interpolating, failed it at 2015.5. One formula now.
    func testPercentileMatchesThePageOnTheReviewsDistribution() {
        var samples = Array(repeating: 1000, count: 94) + [1990] + Array(repeating: 2500, count: 5)
        samples.shuffle()
        XCTAssertEqual(BenchScoring.percentile(samples, 0.95) ?? -1, 2015.5, accuracy: 1e-9)
    }

    func testPercentileOfNothingIsNilNotZero() {
        XCTAssertNil(BenchScoring.percentile([], 0.95), "a ceiling must never be judged on no samples")
    }

    // MARK: normalize — asr_wer.py `norm`

    func testNormalizeMatchesTheScript() {
        XCTAssertEqual(BenchScoring.normalize("It’s $3,162 — due 9:30AM."), ["it's", "3", "162", "due", "9", "30am"])
        XCTAssertEqual(BenchScoring.normalize("  Hello,\tworld\n"), ["hello", "world"])
        XCTAssertEqual(BenchScoring.normalize(""), [])
    }

    // MARK: edit distance and WER

    func testEditDistanceCountsSubstitutionsInsertionsDeletions() {
        XCTAssertEqual(BenchScoring.editDistance(["a", "b", "c"], ["a", "b", "c"]), 0)
        XCTAssertEqual(BenchScoring.editDistance(["a", "b", "c"], ["a", "x", "c"]), 1)
        XCTAssertEqual(BenchScoring.editDistance(["a", "b", "c"], ["a", "c"]), 1)
        XCTAssertEqual(BenchScoring.editDistance(["a", "b", "c"], ["a", "b", "c", "d"]), 1)
        XCTAssertEqual(BenchScoring.editDistance(["a", "b", "c"], []), 3)
        XCTAssertEqual(BenchScoring.editDistance([], ["a", "b"]), 2)
    }

    func testBestErrorsKeepsTheBetterReferenceAndPrefersTheFirstOnATie() {
        let refs = ["three thousand one hundred sixty two dollars", "$3,162"]
        // Spoken rendering: perfect against the verbatim, terrible against the clean form.
        XCTAssertEqual(BenchScoring.bestErrors(hypothesis: "three thousand one hundred sixty two dollars", references: refs).errors, 0)
        // Formatted rendering: perfect against the clean form.
        let formatted = BenchScoring.bestErrors(hypothesis: "$3,162", references: refs)
        XCTAssertEqual(formatted.errors, 0)
        XCTAssertEqual(formatted.words, 2, "the winning reference's word count is the denominator")
        // Tie → the first reference (the verbatim), as the script does.
        let tie = BenchScoring.bestErrors(hypothesis: "x y z", references: ["a b c", "d e f"])
        XCTAssertEqual(tie.words, 3)
        XCTAssertEqual(tie.errors, 3)
        XCTAssertEqual(BenchScoring.bestErrors(hypothesis: "anything", references: []).words, 0)
    }
}
