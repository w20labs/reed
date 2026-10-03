import XCTest
@testable import Reed

/// Pins the 2026-08-25 deep-audit batch: two reproduced formatter crashes and
/// the content-free backend error summary. (The three hot-mic generation
/// fixes in Coordinator+Dictation have no unit seam — they're covered by the
/// same pressGeneration mechanism startRecorder already uses.)
final class AuditBatchTests: XCTestCase {

    // MARK: - version recognizer bounds (crashed: index out of range)

    func testVersionFollowedByTwoTokenNumberAtEndDoesNotCrash() {
        // parseInt consumed "twenty five" and the recognizer indexed past the
        // end looking for "point".
        let out = CorrectionPass.apply("we just shipped version twenty five", active: [.general])
        XCTAssertEqual(out.text, "we just shipped version 25")   // ITN 2026-08-29: a labelled count is a digit
    }

    func testVersionTrailingPointDoesNotCrash() {
        let out = CorrectionPass.apply("we're on version two point", active: [.general])
        XCTAssertEqual(out.text, "we're on version two point")
    }

    func testVersionTwoTokenNumberWithPatchDoesNotCrash() {
        // Same shape one layer deeper: the index after a two-token major
        // could land exactly at tokens.count. (The versionWithZeros/
        // parseIntOrZero pair this guarded folded into dottedRun, 2026-10-02;
        // the bound is now that run parser's.)
        let out = CorrectionPass.apply("update to version twenty five point", active: [.general])
        XCTAssertEqual(out.text, "update to version twenty five point")
    }

    func testVersionWithTwoTokenMajorStillFormats() {
        // Not just "don't crash": a two-token major with a real minor now
        // formats instead of trapping.
        let out = CorrectionPass.apply("we shipped version twenty five point three", active: [.general])
        XCTAssertEqual(out.text, "we shipped v25.3")
    }

    // MARK: - email local-part walk vs claimed tokens (crashed: range trap)

    func testEmailLocalPartCannotConsumeClaimedDomainTokens() {
        // "example dot com" is claimed as a domain first; the email walk for
        // the second address must not re-consume it as a local part — the
        // overlapping edits trapped in CorrectionPass.apply.
        let out = CorrectionPass.apply("example dot com at gmail dot com", active: [.general])
        XCTAssertEqual(out.text, "example.com at gmail.com")
    }

    func testOrdinaryEmailStillJoins() {
        let out = CorrectionPass.apply("email jane dot doe at example dot com", active: [.general])
        XCTAssertEqual(out.text, "email jane.doe@example.com")
    }
}
