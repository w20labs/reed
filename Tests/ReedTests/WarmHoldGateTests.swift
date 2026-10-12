import AVFoundation
import XCTest
@testable import Reed

/// Deferred warm-hold releases and stops (review of PR #25, 2026-10-11): a
/// mutation queued behind a start's segment runs AFTER that start armed
/// capture, so each must re-check that no capture is using the engine. A
/// stale hold (its engine stopped underneath) is not proof of idleness.
/// Probes from the review, kept as the exit tests; `ControlledEngine` stands
/// in for hardware.
final class WarmHoldGateTests: XCTestCase {
    private final class ControlledEngine: AVAudioEngine {
        private let stateLock = NSLock()
        private var simulatedRunning = false
        private var stops = 0
        override var isRunning: Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return simulatedRunning
        }
        override func start() throws {
            stateLock.lock(); defer { stateLock.unlock() }
            simulatedRunning = true
        }
        override func stop() {
            stateLock.lock(); defer { stateLock.unlock() }
            simulatedRunning = false
            stops += 1
        }
        var stopCount: Int {
            stateLock.lock(); defer { stateLock.unlock() }
            return stops
        }
    }

    private func backgroundHold(_ recorder: AudioRecorder, body: @escaping () -> Void)
        -> (release: () -> Void, finish: () -> Void) {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            recorder.engineGate.hold {
                entered.signal()
                proceed.wait()
                body()
            }
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        return ({ proceed.signal() }, { XCTAssertEqual(done.wait(timeout: .now() + 5), .success) })
    }

    func testDeferredStopDoesNotStopNewCapture() throws {
        let recorder = AudioRecorder()
        let engine = ControlledEngine()
        recorder.engine = engine
        try engine.start()
        recorder.bufferQueue.sync { recorder.isCapturing = true }
        let held = backgroundHold(recorder) {
            recorder.bufferQueue.sync { recorder.isCapturing = true }
        }
        _ = recorder.stop()
        XCTAssertEqual(engine.stopCount, 0)
        held.release(); held.finish()
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertTrue(recorder.bufferQueue.sync { recorder.isCapturing })
        _ = recorder.stop()
    }

    func testDeferredStopStillStopsEndedCapture() throws {
        let recorder = AudioRecorder()
        let engine = ControlledEngine()
        recorder.engine = engine
        try engine.start()
        recorder.bufferQueue.sync { recorder.isCapturing = true }
        let held = backgroundHold(recorder) {}
        _ = recorder.stop()
        XCTAssertEqual(engine.stopCount, 0)
        held.release(); held.finish()
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertFalse(engine.isRunning)
    }

    func testDeferredDefaultChangeDoesNotStopColdFallbackCapture() throws {
        guard AudioRecorder.hasAudioInput() else { throw XCTSkip("needs an input node; no real engine is started") }
        let recorder = AudioRecorder()
        let engine = ControlledEngine()
        recorder.engine = engine
        recorder.isPrewarmed = true
        // A warm-held engine has been stopped externally before start resumes.
        recorder.keepWarmReleaseTask = Task { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        let held = backgroundHold(recorder) {
            do { try recorder.armCapture() } catch { XCTFail("armCapture: \(error)") }
        }
        recorder.handleDefaultDeviceChanged()
        held.release(); held.finish()
        XCTAssertTrue(recorder.bufferQueue.sync { recorder.isCapturing })
        XCTAssertTrue(engine.isRunning, "deferred idle release must not stop a newly armed cold fallback")
        XCTAssertEqual(engine.stopCount, 0)
        _ = recorder.stop()
        recorder.keepWarmReleaseTask?.cancel()
    }

    func testDeferredDefaultChangeDoesNotStopNormalWarmResume() throws {
        let recorder = AudioRecorder()
        let engine = ControlledEngine()
        recorder.engine = engine
        try engine.start()
        recorder.keepWarmReleaseTask = Task { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        let held = backgroundHold(recorder) {
            XCTAssertTrue(recorder.resumeFromWarmHold())
            recorder.bufferQueue.sync { recorder.isCapturing = true }
        }
        recorder.handleDefaultDeviceChanged()
        held.release(); held.finish()
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.stopCount, 0)
        _ = recorder.stop()
    }

    @MainActor
    func testDeferredIdleTimeoutDoesNotStopColdFallbackCapture() async throws {
        guard AudioRecorder.hasAudioInput() else { throw XCTSkip("needs an input node; no real engine is started") }
        let recorder = AudioRecorder()
        let engine = ControlledEngine()
        recorder.engine = engine
        recorder.isPrewarmed = true
        recorder.keepWarmIdle = 0.02
        try engine.start()
        XCTAssertTrue(recorder.holdWarmOrStop(shouldHold: true))
        engine.stop() // external graph stop while the warm hold's timer remains
        let stoppedBeforeCapture = engine.stopCount
        let held = backgroundHold(recorder) {
            do { try recorder.armCapture() } catch { XCTFail("armCapture: \(error)") }
        }
        // Completes after the production timer has queued its mutation, while
        // the start segment still owns the gate.
        await recorder.keepWarmReleaseTask?.value
        held.release(); held.finish()
        XCTAssertTrue(recorder.bufferQueue.sync { recorder.isCapturing })
        XCTAssertTrue(engine.isRunning, "old idle timeout stopped the cold fallback capture")
        XCTAssertEqual(engine.stopCount, stoppedBeforeCapture)
        _ = recorder.stop()
        recorder.keepWarmReleaseTask?.cancel()
    }

    /// A live hold armed while a capture is running (beginWarmHold's check
    /// of isCapturing is not under the gate) is still not idle.
    func testAHoldIsNotReleasedUnderAnActiveCapture() throws {
        let recorder = AudioRecorder()
        let engine = ControlledEngine()
        recorder.engine = engine
        try engine.start()
        recorder.keepWarmReleaseTask = Task { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        recorder.bufferQueue.sync { recorder.isCapturing = true }
        recorder.handleDefaultDeviceChanged()
        XCTAssertTrue(engine.isRunning, "the device listener stopped an active capture")
        XCTAssertEqual(engine.stopCount, 0)
        recorder.keepWarmReleaseTask?.cancel()
        _ = recorder.stop()
    }

    func testAStaleHoldIsDroppedAndDoesNotReadAsWarm() throws {
        let recorder = AudioRecorder()
        let engine = ControlledEngine()
        recorder.engine = engine
        recorder.keepWarmReleaseTask = Task { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        // The held engine stopped underneath: a cold start, not a warm one.
        XCTAssertFalse(recorder.isWarm, "a stale hold made a cold start read as warm")
        XCTAssertFalse(recorder.resumeFromWarmHold())
        XCTAssertFalse(recorder.isHoldingWarm, "the cold fallback kept the obsolete hold")
    }
}
