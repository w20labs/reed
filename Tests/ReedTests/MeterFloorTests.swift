import XCTest
@testable import Reed

/// The stateful half of the meter (audit gap, 2026-08-30): `emitLevel`'s
/// self-calibrating noise floor and speech reference. `MeterNormTests`
/// covers the pure mapping; this file covers the state machine that feeds
/// it — which the live segmenter's speech gate also reads, so a bug here
/// silently moves where segments seal.
final class MeterFloorTests: XCTestCase {
    private func floorAndReference(_ recorder: AudioRecorder) -> (floor: Double, reference: Double) {
        recorder.bufferQueue.sync { (recorder.meterNoiseFloorDB, recorder.meterReferenceDB) }
    }

    /// The floor drops instantly to any quieter buffer — calibration must
    /// not lag behind a quiet room.
    func testFloorDropsInstantlyToAQuieterBuffer() {
        let recorder = AudioRecorder()
        recorder.emitLevel(rms: 1e-4)  // −80 dB
        XCTAssertEqual(floorAndReference(recorder).floor, -80, accuracy: 0.5)
    }

    /// Speech far above the floor must not raise it — only near-floor
    /// buffers creep it up, slowly.
    func testSpeechNeverRaisesTheFloorButRoomToneCreepsIt() {
        let recorder = AudioRecorder()
        recorder.emitLevel(rms: 1e-4)                       // floor −80
        recorder.emitLevel(rms: 0.05)                       // speech −26
        XCTAssertEqual(floorAndReference(recorder).floor, -80, accuracy: 0.5,
                       "speech is not room tone; the floor must hold")
        let before = floorAndReference(recorder).floor
        recorder.emitLevel(rms: pow(10, -78.0 / 20))        // −78 dB, inside the 15 dB band
        let after = floorAndReference(recorder).floor
        XCTAssertGreaterThan(after, before, "near-floor buffers recalibrate a changed room")
        XCTAssertLessThanOrEqual(after - before, AudioRecorder.meterNoiseRiseDB + 1e-9,
                                 "…but only by the slow creep rate per buffer")
    }

    /// Fast attack: the reference jumps straight above any louder buffer.
    func testReferenceAttacksAboveTheLoudestBuffer() {
        let recorder = AudioRecorder()
        recorder.emitLevel(rms: 1e-4)
        recorder.emitLevel(rms: 0.05)  // −26 dB
        XCTAssertEqual(floorAndReference(recorder).reference,
                       -26 + AudioRecorder.meterAttackHeadroomDB, accuracy: 0.5)
    }

    /// Slow decay, bounded: long silence must not wind the window down into
    /// room-noise territory.
    func testReferenceDecaysSlowlyAndNeverBelowFloorHeadroom() {
        let recorder = AudioRecorder()
        recorder.emitLevel(rms: 1e-4)
        recorder.emitLevel(rms: 0.05)
        let attacked = floorAndReference(recorder).reference
        recorder.emitLevel(rms: 1e-6)  // one silent buffer
        let onceDecayed = floorAndReference(recorder).reference
        XCTAssertEqual(attacked - onceDecayed, AudioRecorder.meterReferenceDecayDB, accuracy: 1e-6)
        for _ in 0..<2_000 { recorder.emitLevel(rms: 1e-6) }
        let settled = floorAndReference(recorder)
        XCTAssertEqual(settled.reference, settled.floor + AudioRecorder.meterReferenceHeadroomDB,
                       accuracy: 0.5, "decay stops at floor + headroom, whatever the silence length")
    }

    /// A digitally dead channel cannot wind the floor to −120 and meter dither.
    func testDeadChannelFloorIsClamped() {
        let recorder = AudioRecorder()
        for _ in 0..<50 { recorder.emitLevel(rms: 0) }
        XCTAssertEqual(floorAndReference(recorder).floor, AudioRecorder.meterNoiseFloorMinDB,
                       accuracy: 0.5)
    }
}
