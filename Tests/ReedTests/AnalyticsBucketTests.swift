import XCTest
@testable import Reed

/// The buckets ARE the privacy mechanism — ranges, never exact lengths — so
/// every boundary is pinned: an off-by-one silently leaks precision.
final class AnalyticsBucketTests: XCTestCase {
    func testWordBucketBoundaries() {
        let cases: [(Int, String)] = [
            (0, "0"), (1, "1-5"), (5, "1-5"), (6, "6-15"), (15, "6-15"),
            (16, "16-40"), (40, "16-40"), (41, "41-100"), (100, "41-100"),
            (101, "100+"),
        ]
        for (count, expected) in cases {
            XCTAssertEqual(Analytics.wordBucket(count), expected, "words \(count)")
        }
    }

    func testCharBucketBoundaries() {
        let cases: [(Int, String)] = [
            (0, "0"), (1, "1-50"), (50, "1-50"), (51, "51-150"), (150, "51-150"),
            (151, "151-400"), (400, "151-400"), (401, "401-1000"),
            (1000, "401-1000"), (1001, "1000+"),
        ]
        for (count, expected) in cases {
            XCTAssertEqual(Analytics.charBucket(count), expected, "chars \(count)")
        }
    }
}
