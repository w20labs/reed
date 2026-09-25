import XCTest
@testable import Reed

/// `FileLog.trimmed` is the pure retention policy behind the consolidated
/// reed.log — a 72h age cutoff, with a size backstop for pathological
/// volume within that window. Exercised directly so the policy stays
/// correct without touching the real file.
final class FileLogTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func line(_ message: String, hoursAgo: Double) -> String {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-hoursAgo * 3600))
        return "\(stamp) [test] INFO: \(message)"
    }

    func testDropsLinesOlderThan72Hours() {
        let fresh = line("fresh", hoursAgo: 1)
        let boundary = line("boundary", hoursAgo: 72)
        let stale = line("stale", hoursAgo: 73)
        let survivors = FileLog.trimmed(lines: [stale, boundary, fresh], now: now)
        XCTAssertEqual(survivors, [boundary, fresh])
    }

    func testKeepsMalformedLinesRatherThanDroppingSilently() {
        let malformed = "not a timestamp at all"
        let survivors = FileLog.trimmed(lines: [malformed], now: now)
        XCTAssertEqual(survivors, [malformed])
    }

    func testSizeBackstopDropsOldestSurvivorsWhenStillOversized() {
        // All within 72h (age trim keeps everything), but collectively over
        // the size cap — the backstop must drop the OLDEST first.
        let big = String(repeating: "x", count: FileLog.sizeCapBytes / 2)
        let oldest = "\(line("first", hoursAgo: 3))\(big)"
        let middle = "\(line("second", hoursAgo: 2))\(big)"
        let newest = "\(line("third", hoursAgo: 1))\(big)"
        let survivors = FileLog.trimmed(lines: [oldest, middle, newest], now: now)
        XCTAssertFalse(survivors.contains(oldest))
        XCTAssertTrue(survivors.contains(newest))
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(FileLog.trimmed(lines: [], now: now), [])
    }
}
