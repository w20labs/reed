import AVFoundation
import XCTest
@testable import Reed

/// The engine gate (crash report 2026-10-11-231422): AirPods connecting
/// during a press slowed prewarm past the warming watchdog, whose main-thread
/// rebuild swapped in a fresh engine while `start()` was between prewarm and
/// `engine.start()` on the cooperative pool. Starting the never-prepared
/// engine raised "inputNode != nullptr || outputNode != nullptr" — SIGABRT.
final class EngineGateTests: XCTestCase {

    /// Runs `segment` holding `gate` on a background thread; returns once the
    /// segment has entered, plus a release to let it finish and a wait.
    private func holdInBackground(
        _ gate: EngineGate, segment: @escaping () -> Void = {}
    ) -> (release: () -> Void, finished: () -> Void) {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.hold {
                entered.signal()
                proceed.wait()
                segment()
            }
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        return ({ proceed.signal() },
                { XCTAssertEqual(done.wait(timeout: .now() + 5), .success) })
    }

    func testMainMutationWaitsForTheHolderWithoutBlockingMain() {
        let gate = EngineGate()
        var log: [String] = []
        let lock = NSLock()
        let held = holdInBackground(gate) { lock.lock(); log.append("segment"); lock.unlock() }
        // Returns at once (a blocking main would hang here) and runs nothing.
        gate.mutate { lock.lock(); log.append("mutation"); lock.unlock() }
        lock.lock(); XCTAssertEqual(log, []); lock.unlock()
        held.release()
        held.finished()
        XCTAssertEqual(log, ["segment", "mutation"])
    }

    func testFreeGateRunsAMainMutationNow() {
        let gate = EngineGate()
        var ran = false
        gate.mutate { ran = true }
        XCTAssertTrue(ran)
    }

    /// The production path the watchdog takes: `invalidate()` from main while
    /// a start/prewarm segment holds the engine must not swap it underneath.
    func testInvalidateFromMainNeverReplacesTheEngineMidSegment() {
        let recorder = AudioRecorder()
        let before = recorder.engine
        var sameInsideSegment = false
        let held = holdInBackground(recorder.engineGate) {
            sameInsideSegment = recorder.engine === before
        }
        recorder.invalidate()
        held.release()
        held.finished()
        XCTAssertTrue(sameInsideSegment, "the engine was replaced while a segment held it")
        XCTAssertFalse(recorder.engine === before, "the queued replacement never ran")
    }

    /// A config change queued behind a segment that itself replaced the
    /// engine is about an engine that is gone: it must not tear down the new one.
    func testQueuedConfigChangeForAReplacedEngineIsIgnored() {
        let recorder = AudioRecorder()
        var replacement: AVAudioEngine?
        let held = holdInBackground(recorder.engineGate) {
            recorder.invalidate()
            replacement = recorder.engine
        }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: recorder.engine)
        held.release()
        held.finished()
        XCTAssertTrue(recorder.engine === replacement)
    }

    /// The crash itself, through `start()`: the engine prewarm readied is
    /// replaced from main before capture is armed. Refused with a catchable
    /// error, never started.
    @MainActor
    func testEngineReplacedAfterPrewarmIsRefusedNotStarted() async throws {
        // invalidate() with isPrewarmed set touches the real input node.
        try skipIfDefaultInputIsBluetooth()
        let recorder = AudioRecorder()
        recorder.isPrewarmed = true
        recorder.afterPrewarmForTesting = {
            DispatchQueue.main.sync { recorder.rebuildEngineForDeviceChange() }
        }
        do {
            try await recorder.start()
            XCTFail("start() armed capture on a replaced engine")
        } catch AudioRecorder.RecorderError.engineReplaced {
        } catch {
            XCTFail("expected engineReplaced, got \(error)")
        }
    }

    /// The backstop: an NSException from `engine.start()` comes back as an
    /// error. A fresh engine with no nodes raises exactly the crash's one.
    func testEngineStartExceptionIsThrownNotFatal() {
        let recorder = AudioRecorder()
        XCTAssertThrowsError(try recorder.startEngineCatchingExceptions()) { error in
            guard case AudioRecorder.RecorderError.engineStartRaised = error else {
                return XCTFail("expected engineStartRaised, got \(error)")
            }
        }
    }
}
