import XCTest
@testable import Reed

/// The #297 race, pinned (audit gap 2, 2026-08-30): `stopWithSegments()`
/// must hand back the full WAV, the byte the unprocessed tail starts at,
/// and every seal the main actor had not taken yet — in one bufferQueue
/// turn, so no seal can land after it and none is lost. Also covers the
/// `segmentIfDue` wiring (gap 3): the rms→dB→speech gate against the
/// meter's noise floor, the appended-bytes bookkeeping, and the
/// notify-on-main callback.
final class StopWithSegmentsTests: XCTestCase {
    private let chunk = 3_200  // 100 ms at 16 kHz mono Int16

    private func loudChunk() -> Data {
        var data = Data(capacity: chunk)
        for sampleIndex in 0..<(chunk / 2) {
            var sample = Int16(sampleIndex % 2 == 0 ? 8_000 : -8_000)
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Feed a real speech→pause take through the live wiring, leave the seal
    /// untaken, stop — everything travels out together.
    func testStopHandsBackWavTailOffsetAndUntakenSeals() {
        let recorder = AudioRecorder()
        let sealed = expectation(description: "seal notified on main")
        sealed.assertForOverFulfill = false
        recorder.armSegmenting { sealed.fulfill() }
        recorder.bufferQueue.sync { recorder.isCapturing = true }

        // Calibrate the meter floor the way capture would: one quiet buffer.
        recorder.emitLevel(rms: 1e-4)  // −80 dB → floor drops to −80
        let speech = loudChunk()
        let silence = Data(count: chunk)
        for _ in 0..<25 {  // 2.5 s of speech, above the −80+8 dB gate
            recorder.emitLevel(rms: 0.05)
            recorder.bufferQueue.sync {
                recorder.pcmBuffer.append(speech)
                recorder.segmentIfDue(rms: 0.05)
            }
        }
        for _ in 0..<9 {   // 900 ms of pause → a .pause seal
            recorder.emitLevel(rms: 1e-6)
            recorder.bufferQueue.sync {
                recorder.pcmBuffer.append(silence)
                recorder.segmentIfDue(rms: 1e-6)
            }
        }
        wait(for: [sealed], timeout: 2)
        let waiting = recorder.bufferQueue.sync { recorder.pendingSealed.count }
        XCTAssertEqual(waiting, 1, "the pause after 2.5 s of speech must seal exactly one segment")

        let stopped = recorder.stopWithSegments()
        XCTAssertEqual(stopped.wav.count, 44 + 34 * chunk, "full recording, one WAV header")
        XCTAssertEqual(stopped.pending.count, 1, "the untaken seal travels out with the stop")
        XCTAssertEqual(stopped.pending[0].reason, .pause)
        XCTAssertGreaterThan(stopped.sealedOffset, 0, "the tail starts after the sealed segment")
        XCTAssertLessThanOrEqual(stopped.sealedOffset, 34 * chunk)
        recorder.bufferQueue.sync {
            XCTAssertFalse(recorder.segmentingEnabled, "no seal may land after stop")
            XCTAssertTrue(recorder.pendingSealed.isEmpty)
        }
    }

    /// A silent recording returns no WAV — but the seals are still handed
    /// back, never dropped with it.
    func testSilentStopStillHandsBackPendingSeals() {
        let recorder = AudioRecorder()
        let wav = WAVWriter.wrap(pcm: Data(count: chunk), sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        recorder.bufferQueue.sync {
            recorder.isCapturing = true
            recorder.pcmBuffer = Data(count: 10 * chunk)  // all zeros → silent
            recorder.pendingSealed = [AudioRecorder.SealedSegment(wav: wav, reason: .pause, rmsDB: -30)]
        }
        let stopped = recorder.stopWithSegments()
        XCTAssertTrue(stopped.wav.isEmpty, "silence never reaches transcription")
        XCTAssertEqual(stopped.pending.count, 1, "a seal is never lost to the silence guard")
    }

    func testStopWithoutCaptureIsEmptyAndRepeatable() {
        let recorder = AudioRecorder()
        let first = recorder.stopWithSegments()
        XCTAssertTrue(first.wav.isEmpty)
        XCTAssertTrue(first.pending.isEmpty)
        XCTAssertEqual(first.sealedOffset, 0)
    }

    func testSecondStopReturnsNothing() {
        let recorder = AudioRecorder()
        recorder.bufferQueue.sync {
            recorder.isCapturing = true
            recorder.pcmBuffer = loudChunk()
        }
        _ = recorder.stopWithSegments()
        let second = recorder.stopWithSegments()
        XCTAssertTrue(second.wav.isEmpty, "stop is one-shot; a double release must not re-process")
    }

    /// The arm/disarm gate: nothing observes, nothing seals, when disarmed.
    func testSegmentIfDueIsInertWhenDisarmed() {
        let recorder = AudioRecorder()
        recorder.bufferQueue.sync {
            recorder.pcmBuffer.append(self.loudChunk())
            recorder.segmentIfDue(rms: 0.05)
            XCTAssertTrue(recorder.pendingSealed.isEmpty)
        }
    }
}
