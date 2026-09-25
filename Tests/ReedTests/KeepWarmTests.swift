import XCTest
@testable import Reed

/// Holding a Bluetooth link warm between dictations
/// (design: "Bluetooth · holding the link warm").
///
/// Measured on AirPods: 1855 ms median from hotkey to audible, ~92% of it the
/// A2DP→call-profile switch, paid again every press because `stop()` tore the
/// stream down. Held open and HAL-muted, the same press is ~132 ms.
final class KeepWarmTests: XCTestCase {

    // MARK: - the confirmation threshold

    @MainActor
    func testAColdStartStillFiltersTheConnectClick() {
        // AirPods emit one loud click as a link comes up, sometimes >20% of
        // full scale. Treating it as "the mic is live" is the bug the 3-buffer
        // rule exists to prevent, and a cold start is exactly when it happens.
        let recorder = AudioRecorder()
        recorder.resumedFromWarmHold = false
        recorder.capturingFromBluetooth = true
        XCTAssertEqual(recorder.requiredLoudBuffers, AudioRecorder.captureReadyConsecutiveBuffers)
        XCTAssertGreaterThan(recorder.requiredLoudBuffers, 1,
                             "a single loud buffer must never count as signal on a cold link")
    }

    @MainActor
    func testWiredColdStartSkipsTheClickFilter() {
        // Wired and built-in mics have no connect click — the 3-buffer wait
        // was ~200 ms of self-inflicted cold-start latency (2026-08-19).
        let recorder = AudioRecorder()
        recorder.resumedFromWarmHold = false
        recorder.capturingFromBluetooth = false
        XCTAssertEqual(recorder.requiredLoudBuffers, 1)
    }

    @MainActor
    func testAWarmResumeDoesNotWaitForBuffersItDoesNotNeed() {
        // Resumed from a hold the link never went down, so there is no connect
        // click to filter — and 3 buffers at 4096/48 kHz is 256 ms, which would
        // be most of the latency this whole change exists to remove.
        let recorder = AudioRecorder()
        recorder.resumedFromWarmHold = true
        XCTAssertEqual(recorder.requiredLoudBuffers, 1)
    }

    @MainActor
    func testTheHoldIsOffUntilSomethingTurnsItOn() {
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.isHoldingWarm)
        XCTAssertFalse(recorder.shouldHoldWarm, "nothing is held until a device is known to benefit")
    }

    @MainActor
    func testAStoppedEngineIsNeverHeld() {
        // holdWarmOrStop must not claim a hold it doesn't have: a false claim
        // would make the next press skip engine.start() and record silence
        // forever — the dead-mic failure this area has repeatedly produced.
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.holdWarmOrStop(shouldHold: true),
                       "with no running engine there is nothing to hold")
        XCTAssertFalse(recorder.isHoldingWarm)
    }

    @MainActor
    func testResumingWithoutAHoldReportsNoResume() {
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.resumeFromWarmHold(),
                       "a press with nothing held must take the normal cold path")
    }

    // MARK: - the HAL mute this all rests on

    func testMutingIsVerifiedNotAssumed() {
        // The whole design rests on macOS guaranteeing silence — that is why
        // there is no indicator. If the property doesn't stick, Reed must know,
        // because the alternative is holding a live mic with no indicator.
        XCTAssertTrue(ProcessAudio.setInputMuted(true))
        XCTAssertTrue(ProcessAudio.isInputMuted)
        XCTAssertTrue(ProcessAudio.setInputMuted(false))
        XCTAssertFalse(ProcessAudio.isInputMuted)
    }

    // MARK: - levels

    func testDigitalSilenceReadsAsTheFloor() {
        let silence = Data(repeating: 0, count: 3200)
        let levels = RecordingLevels.measure(pcm: silence)
        XCTAssertEqual(levels.peakDB, RecordingLevels.floorDB)
        XCTAssertEqual(levels.rmsDB, RecordingLevels.floorDB)
        XCTAssertEqual(levels.sampleCount, 1600)
    }

    func testAnEmptyBufferDoesNotDivideByZero() {
        let levels = RecordingLevels.measure(pcm: Data())
        XCTAssertEqual(levels.sampleCount, 0)
        XCTAssertEqual(levels.peakDB, RecordingLevels.floorDB)
    }

    func testFullScaleReadsAsZeroDB() {
        var pcm = Data()
        for _ in 0..<100 { withUnsafeBytes(of: Int16.max.littleEndian) { pcm.append(contentsOf: $0) } }
        let levels = RecordingLevels.measure(pcm: pcm)
        XCTAssertEqual(levels.peakDB, 0, accuracy: 0.01)
        XCTAssertEqual(levels.rmsDB, 0, accuracy: 0.01)
    }

    func testQuietSpeechStaysAboveTheSilenceGuard() {
        // -30 dBFS is soft but real speech. It must not be binned as silence:
        // that regression shipped once already and read as "No audio captured"
        // after a genuine dictation.
        let amplitude = Int16(32768.0 * pow(10, -30.0 / 20.0))
        var pcm = Data()
        for _ in 0..<1000 { withUnsafeBytes(of: amplitude.littleEndian) { pcm.append(contentsOf: $0) } }
        let levels = RecordingLevels.measure(pcm: pcm)
        XCTAssertGreaterThan(levels.peakDB, AudioRecorder.silenceFloorDB)
    }
}
