import XCTest
@testable import Reed

/// The real mic-ready guard (replacing the deleted fake-test file, audit
/// 2026-08-30): a Bluetooth device pinned while still in A2DP reports zero
/// input channels for a moment — `waitForUsableFormat` must poll through
/// that window and only then throw `noInput`, because failing early turned
/// "AirPods selected" into a permanent "No microphone found". And the
/// reading it hands back must be the one that passed, not a later read.
final class InputFormatWaitTests: XCTestCase {
    private typealias Reading = (rate: Double, channels: Int)
    private func wait(pollMs: Int, timeoutMs: Int, read: () -> Reading) async throws -> (reading: Reading, waitedMs: Int) {
        try await AudioRecorder.waitForUsableFormat(pollMs: pollMs, timeoutMs: timeoutMs, read: read,
                                                    rateAndChannels: { ($0.rate, $0.channels) })
    }

    func testReadyFormatReturnsImmediately() async throws {
        let result = try await wait(pollMs: 1, timeoutMs: 50) { (48_000.0, 1) }
        XCTAssertEqual(result.waitedMs, 0, "a healthy device must not be made to wait")
        XCTAssertEqual(result.reading.rate, 48_000)
    }

    func testNotReadyDevicePollsUntilTheFormatArrives() async throws {
        var reads = 0
        let result = try await wait(pollMs: 1, timeoutMs: 200) {
            reads += 1
            return reads > 3 ? (48_000.0, 1) : (0.0, 0)  // A2DP window, then ready
        }
        XCTAssertEqual(result.waitedMs, 3, "three not-ready polls, then the format arrived")
        XCTAssertEqual(reads, 4, "initial read + one read per poll; the fourth was ready")
    }

    /// The contract (review 2026-09-01): the reading returned IS the one
    /// that passed validation — no extra read after it, which the transient
    /// could turn back into zero channels.
    func testTheReturnedReadingIsTheOneThatPassed() async throws {
        var reads = 0
        let result = try await wait(pollMs: 1, timeoutMs: 200) {
            reads += 1
            return reads >= 3 ? (48_000.0, reads) : (48_000.0, 0)  // channels carry the read number
        }
        XCTAssertEqual(result.reading.channels, 3, "the third read passed; that exact reading comes back")
        XCTAssertEqual(reads, 3, "nothing is read after the reading that passed")
    }

    /// Zero channels alone (rate fine) is still not usable — that is the
    /// exact A2DP shape from the field.
    func testZeroChannelsAloneIsNotReady() async throws {
        var reads = 0
        _ = try await wait(pollMs: 1, timeoutMs: 200) {
            reads += 1
            return reads > 1 ? (24_000.0, 1) : (24_000.0, 0)
        }
        XCTAssertEqual(reads, 2, "a zero-channel format must be polled past, not accepted")
    }

    func testNeverReadyThrowsNoInputAfterTheTimeout() async {
        do {
            _ = try await wait(pollMs: 2, timeoutMs: 10) { (0.0, 0) }
            XCTFail("a device that never becomes ready must throw")
        } catch let error as AudioRecorder.RecorderError {
            XCTAssertEqual(error, .noInput)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
