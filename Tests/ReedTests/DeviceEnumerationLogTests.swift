import XCTest
@testable import Reed

/// Review 2026-09-04: the device enumeration ran at UI-tick rate (the
/// Settings microphone row enumerates twice per body pass) and each call
/// logged the full microphone inventory — 89% of reed.log on a fresh
/// install, evicting real history from the capped file that rides support
/// reports. Enumerating must write nothing for the healthy case, and a
/// rejection must not repeat per tick.
final class DeviceEnumerationLogTests: XCTestCase {
    private let tlog = Log(category: "test")

    /// The log lines written between two unique markers. Bounded by markers
    /// rather than a line count (review P3): the shared test log can be
    /// trimmed by an append, which shrinks it and would hide new lines.
    private func linesWritten(during body: () -> Void) throws -> [String] {
        let start = "marker-start-\(UUID().uuidString)"
        let end = "marker-end-\(UUID().uuidString)"
        tlog.info(start)
        body()
        tlog.info(end)
        FileLog.waitForPendingWrites()
        let text = try String(contentsOf: FileLog.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        guard let s = lines.lastIndex(where: { $0.contains(start) }),
              let e = lines.lastIndex(where: { $0.contains(end) }), s < e else {
            XCTFail("markers not found in the log — the file was trimmed or not written; no verdict")
            return []
        }
        return Array(lines[(s + 1)..<e])
    }

    func testEnumeratingDevicesAtTickRateWritesNothingToTheLog() throws {
        let written = try linesWritten {
            // The two Settings-row reads and the pickers' read, at a tick rate.
            for _ in 0..<20 {
                _ = AudioInputDevice.availableDevices()
                _ = AudioInputDevice.pinnableDevices()
                _ = AudioInputDevice.hasBluetoothInput()
            }
        }
        let inventory = written.filter { $0.contains("availableDevices") || $0.contains("candidate id(s)") }
        XCTAssertTrue(inventory.isEmpty, "the healthy inventory must never be logged; got \(inventory.count) lines")
        // A device this Mac rejects (no input streams, or dead) may log its
        // verdict — once. Sixty enumerations must not produce it sixty times.
        let rejections = written.filter { $0.contains("hasInputStreams=") || $0.contains("property query failed") }
        let distinct = Set(rejections.map { $0.drop(while: { $0 != "[" }) })
        XCTAssertEqual(rejections.count, distinct.count, "a rejection repeated per tick: \(rejections.prefix(3))")
        let other = written.filter { !$0.contains("[audio]") }
        XCTAssertTrue(other.isEmpty, "enumeration wrote non-audio lines: \(other.prefix(3))")
    }

    override func tearDown() {
        AudioInputDevice.hasInputStreamsForTests = nil
        AudioInputDevice.aliveQueryStatusForTests = nil
        super.tearDown()
    }

    /// Review 2026-09-04 (P1): a device rejected on every enumeration used
    /// to log its verdict on every tick. It logs once per verdict, and
    /// again only when the verdict changes.
    func testADeadDeviceLogsItsRejectionOncePerVerdictNotPerTick() throws {
        let deviceCount = AudioInputDevice.availableDevices().count
        try XCTSkipUnless(deviceCount > 0, "needs at least one input device to reject")
        AudioInputDevice.hasInputStreamsForTests = { _ in false }
        let dead = try linesWritten {
            for _ in 0..<20 { _ = AudioInputDevice.availableDevices() }
        }.filter { $0.contains("hasInputStreams=false") }
        XCTAssertEqual(dead.count, deviceCount, "one rejection line per device for twenty ticks; got \(dead.count)")

        // Recovery is silent; the same failure again is a new transition.
        AudioInputDevice.hasInputStreamsForTests = { _ in true }
        let recovered = try linesWritten { _ = AudioInputDevice.availableDevices() }
            .filter { $0.contains("hasInputStreams=") }
        XCTAssertTrue(recovered.isEmpty, "a device passing both checks must not log")
        AudioInputDevice.hasInputStreamsForTests = { _ in false }
        let again = try linesWritten { for _ in 0..<5 { _ = AudioInputDevice.availableDevices() } }
            .filter { $0.contains("hasInputStreams=false") }
        XCTAssertEqual(again.count, deviceCount, "a device that flaps logs each failure once")
    }

    /// Same rule for a CoreAudio alive query that keeps failing.
    func testAFailingAliveQueryLogsOncePerStatusNotPerTick() throws {
        let deviceCount = AudioInputDevice.availableDevices().count
        try XCTSkipUnless(deviceCount > 0, "needs at least one input device to probe")
        AudioInputDevice.aliveQueryStatusForTests = { _ in OSStatus(-50) }
        let failed = try linesWritten { for _ in 0..<20 { _ = AudioInputDevice.availableDevices() } }
            .filter { $0.contains("property query failed, status=-50") }
        XCTAssertEqual(failed.count, deviceCount, "one line per device for twenty failing ticks; got \(failed.count)")

        AudioInputDevice.aliveQueryStatusForTests = { _ in OSStatus(-4) }
        let changed = try linesWritten { for _ in 0..<5 { _ = AudioInputDevice.availableDevices() } }
            .filter { $0.contains("property query failed, status=-4") }
        XCTAssertEqual(changed.count, deviceCount, "a different status is a new line, once")
    }
}
