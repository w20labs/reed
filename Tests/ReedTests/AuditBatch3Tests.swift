import XCTest
@testable import Reed

/// Pins deep-audit batch 3 (findings 11–14): the pure seams — anchor
/// distinctness and download-failure copy. The UI/state fixes (persisted
/// revert anchor, error auto-clear identity) have no unit seam and were
/// verified by trace.
final class AuditBatch3Tests: XCTestCase {

    // MARK: - 14f: subsumed anchors are one piece of evidence, not two

    func testSubsumedAnchorDoesNotActivateDomainAlone() {
        // "irrevocable trust" (strong) contains "trust" (weak) — one phrase
        // must not count as the two distinct anchors activation requires.
        let session = CorrectionSession()
        _ = session.apply("we set up an irrevocable trust")
        XCTAssertFalse(session.active.contains(.estate))
        // The gated map therefore stays locked: plain English survives.
        let out = session.apply("take the interstate highway to the office")
        XCTAssertEqual(out.text, "take the interstate highway to the office")
    }

    func testTwoIndependentAnchorsStillActivate() {
        let session = CorrectionSession()
        _ = session.apply("we set up an irrevocable trust")
        _ = session.apply("the probate hearing is next week")
        XCTAssertTrue(session.active.contains(.estate))
    }

    // MARK: - 14c: download failures name their real cause

    func testDiskFullFailureDoesNotBlameTheNetwork() {
        let diskFull = NSError(domain: NSCocoaErrorDomain,
                               code: NSFileWriteOutOfSpaceError)
        let message = ModelDownloadController.failureMessage(for: diskFull)
        XCTAssertTrue(message.contains("disk space"))
        XCTAssertFalse(message.contains("connection"))
    }

    func testNetworkFailureKeepsTheConnectionCopy() {
        let offline = URLError(.notConnectedToInternet)
        let message = ModelDownloadController.failureMessage(for: offline)
        XCTAssertTrue(message.contains("connection"))
    }

    func testUnknownFailureSaysTryAgainAndWhereToReport() {
        // P15: one model, no other quality to suggest — the honest advice is
        // retry, then report it.
        struct LoadFailed: Error {}
        let message = ModelDownloadController.failureMessage(for: LoadFailed())
        XCTAssertTrue(message.contains("Try again"))
        XCTAssertTrue(message.contains("report"))
        XCTAssertFalse(message.contains("quality"))
    }

    // MARK: - 14d: the notInstalled error carries a button now

    func testGenericErrorDefaultsToNoAction() {
        let error = DictationError.generic(headline: "h", detail: "d", raw: "r")
        XCTAssertNil(error.actionTitle)
    }

    func testGenericErrorCanCarryOpenSettings() {
        let error = DictationError.generic(headline: "h", detail: "d", raw: "r",
                                           action: .openSettings)
        XCTAssertEqual(error.actionTitle, "Open Settings")
    }
}
