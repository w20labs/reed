import XCTest
@testable import Reed

/// The bar must be continuous across the download → prepare boundary, and it
/// must never claim to be finished before the model has actually loaded.
final class ModelPrepTests: XCTestCase {
    func testDownloadOwnsTheFirstShareOfTheBar() {
        XCTAssertEqual(ModelPrep.barFraction(downloadFraction: 0, preparingSince: nil), 0, accuracy: 0.0001)
        XCTAssertEqual(ModelPrep.barFraction(downloadFraction: 0.5, preparingSince: nil),
                       ModelPrep.downloadShare * 0.5, accuracy: 0.0001)
    }

    func testTheBarDoesNotJumpBackWhenPreparationTakesOver() {
        let start = Date()
        // Last frame of the download, first frame of the load.
        let endOfDownload = ModelPrep.barFraction(downloadFraction: 0.999, preparingSince: nil)
        let startOfPrepare = ModelPrep.barFraction(downloadFraction: 1, preparingSince: start, now: start)
        XCTAssertGreaterThanOrEqual(startOfPrepare, endOfDownload,
                                    "the bar must never run backwards at the handover")
    }

    func testPreparingNeverReachesFull() {
        let start = Date()
        // Well past the estimate — an over-running load must still not claim 100%.
        let late = ModelPrep.barFraction(downloadFraction: 1,
                                         preparingSince: start,
                                         now: start.addingTimeInterval(ModelPrep.estimate * 10))
        XCTAssertLessThanOrEqual(late, ModelPrep.ceiling)
        XCTAssertLessThan(late, 1.0, "only an actually-loaded model finishes the bar")
    }

    func testDetailSwitchesFromMegabytesToAnEstimate() {
        XCTAssertEqual(ModelPrep.detail(downloadFraction: 0.5, sizeMB: 626, preparingSince: nil),
                       "50% · 313 of 626 MB")
        let start = Date()
        XCTAssertEqual(ModelPrep.detail(downloadFraction: 1, sizeMB: 626,
                                        preparingSince: start, now: start),
                       "about 60s left")
        // Past the estimate it stops guessing rather than counting to zero.
        XCTAssertEqual(ModelPrep.detail(downloadFraction: 1, sizeMB: 626,
                                        preparingSince: start,
                                        now: start.addingTimeInterval(ModelPrep.estimate + 30)),
                       "almost there")
    }
}
