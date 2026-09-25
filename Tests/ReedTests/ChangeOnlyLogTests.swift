import XCTest
@testable import Reed

/// Review 2026-09-04 (P1): rejection diagnostics on the enumeration path
/// must log on change, not on every tick.
final class ChangeOnlyLogTests: XCTestCase {
    func testARepeatedMessageLogsOnce() {
        let log = ChangeOnlyLog()
        let decisions = (0..<20).map { _ in log.shouldLog(key: "device-7", message: "hasInputStreams=false isAlive=true") }
        XCTAssertEqual(decisions.filter { $0 }.count, 1, "twenty ticks of the same rejection must produce one line")
        XCTAssertTrue(decisions[0])
    }

    func testAChangedMessageLogsAgain() {
        let log = ChangeOnlyLog()
        XCTAssertTrue(log.shouldLog(key: "device-7", message: "isAlive=false"))
        XCTAssertFalse(log.shouldLog(key: "device-7", message: "isAlive=false"))
        XCTAssertTrue(log.shouldLog(key: "device-7", message: "hasInputStreams=false"))
    }

    func testKeysAreIndependent() {
        let log = ChangeOnlyLog()
        XCTAssertTrue(log.shouldLog(key: "device-7", message: "isAlive=false"))
        XCTAssertTrue(log.shouldLog(key: "device-9", message: "isAlive=false"))
    }

    func testClearingAKeyLetsATransitionLogAgain() {
        let log = ChangeOnlyLog()
        XCTAssertTrue(log.shouldLog(key: "device-7", message: "isAlive=false"))
        log.clear(key: "device-7")  // the device recovered
        XCTAssertTrue(log.shouldLog(key: "device-7", message: "isAlive=false"), "a device that flaps logs each failure")
    }
}
