import XCTest
@testable import Reed

/// Overlap lifecycle (review 2026-08-30, R2/R3/R7/R10/R12/R13).
@MainActor
final class OverlapLifecycleTests: XCTestCase {
    private func makeCoordinator() -> Coordinator {
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
        return Coordinator()
    }

    /// R2: cancelling while the release path is running must not touch the
    /// session — it would drop every head segment and inject the tail alone.
    func testCancelDuringTranscribingLeavesTheOverlapSessionAlone() {
        let c = makeCoordinator()
        c.overlap.arm()
        c.overlap.enqueue(sealedBy: .pause) { .init("head") }
        c.state = .transcribing
        c.cancelDictation()
        XCTAssertTrue(c.overlap.isArmed)
        XCTAssertEqual(c.overlap.segmentCount, 1)
        XCTAssertEqual(c.state, .transcribing)
        // A live press is cancelled for real.
        c.state = .recording
        c.cancelDictation()
        XCTAssertFalse(c.overlap.isArmed)
        XCTAssertEqual(c.overlap.segmentCount, 0)
        XCTAssertEqual(c.state, .idle)
    }

    /// R3: seals wait on the audio queue until taken; a take empties them.
    func testSealedSegmentsAreTakenOnceAndInOrder() {
        let recorder = AudioRecorder()
        let wav = WAVWriter.wrap(pcm: Data(count: 3200), sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        recorder.bufferQueue.sync {
            recorder.pendingSealed = [
                AudioRecorder.SealedSegment(wav: wav, reason: .pause, rmsDB: -30),
                AudioRecorder.SealedSegment(wav: wav, reason: .cap, rmsDB: -25)
            ]
        }
        let taken = recorder.takeSealedSegments()
        XCTAssertEqual(taken.map(\.reason), [.pause, .cap])
        XCTAssertEqual(taken.map(\.rmsDB), [-30, -25])
        XCTAssertTrue(recorder.takeSealedSegments().isEmpty)
    }

    /// R3: a late notification from a previous press enqueues nothing.
    func testStaleSealNotificationIsIgnored() {
        let c = makeCoordinator()
        c.overlap.arm()
        let stale = c.pressGeneration
        c.pressGeneration &+= 1
        c.recorder.bufferQueue.sync {
            c.recorder.pendingSealed = [AudioRecorder.SealedSegment(wav: Data(count: 44), reason: .pause, rmsDB: -30)]
        }
        c.drainSealedSegments(generation: stale)
        XCTAssertEqual(c.overlap.segmentCount, 0, "a seal from an earlier press must never join this one")
        c.drainSealedSegments(generation: c.pressGeneration)
        XCTAssertEqual(c.overlap.segmentCount, 1)
    }

    /// R7/R12: abortPress tears down every per-press resource.
    func testAbortPressTearsDownKeepWarmAndOverlap() {
        let c = makeCoordinator()
        c.overlap.arm()
        c.overlap.enqueue(sealedBy: .pause) { .init("x") }
        c.keepWarmTask = Task { @MainActor in while !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) } }
        c.abortPress()
        XCTAssertNil(c.keepWarmTask)
        XCTAssertFalse(c.overlap.isArmed)
        XCTAssertEqual(c.overlap.segmentCount, 0)
    }
}
