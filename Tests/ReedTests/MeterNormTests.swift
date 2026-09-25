import XCTest
@testable import Reed

/// Pins the HUD meter's self-calibrating RMS→bar mapping: bars are drawn
/// relative to the session's rolling speech reference (fast attack, slow
/// decay, floored just above the rolling noise floor) over a 25 dB window —
/// and the silence gate is noise-floor-relative, so the wave reads the same
/// at laptop or desk distance and at any input gain, while silence stays flat.
final class MeterNormTests: XCTestCase {
    func testEnvironmentIndependence() {
        // A sustained level IS its own reference (fast attack), so quiet
        // desk-mic speech and loud close-up speech render identical bars.
        let desk = AudioRecorder.meterNorm(rmsDB: -35, referenceDB: -35, noiseFloorDB: -60)
        let close = AudioRecorder.meterNorm(rmsDB: -15, referenceDB: -15, noiseFloorDB: -40)
        XCTAssertEqual(desk, close)
        XCTAssertGreaterThan(desk, 0.9)
    }

    func testQuietChainStillMeters() {
        // The Studio regression: an external mic chain at low input gain puts
        // speech RMS below the old absolute -42 gate (peaks still passed the
        // recording gate, so dictation worked while the wave sat flat). With
        // the gate relative to the chain's own noise floor, it meters fully.
        let v = AudioRecorder.meterNorm(rmsDB: -46, referenceDB: -46, noiseFloorDB: -62)
        XCTAssertGreaterThan(v, 0.9)
    }

    func testSilenceStaysFlat() {
        XCTAssertEqual(AudioRecorder.meterNorm(rmsDB: -120, referenceDB: -15, noiseFloorDB: -55), 0)
        // At or inside the gate margin above the floor still counts as silence.
        XCTAssertEqual(
            AudioRecorder.meterNorm(
                rmsDB: -55 + AudioRecorder.meterGateDB, referenceDB: -15, noiseFloorDB: -55), 0)
    }

    func testMonotonicWithinWindow() {
        // Rising level under a fixed reference → non-decreasing bars, from
        // flat inside the gate up to full at the reference.
        let points = [-54.0, -40, -35, -30, -25, -20, -18]
            .map { AudioRecorder.meterNorm(rmsDB: $0, referenceDB: -18, noiseFloorDB: -60) }
        XCTAssertEqual(points, points.sorted())
        XCTAssertEqual(points.first, 0)   // inside the gate margin
        XCTAssertEqual(points.last, 1)    // at the reference
    }

    func testReferenceFloorPreventsNoiseAmplification() {
        // Long silence decays the reference to its floor (noise floor +
        // headroom); room tone just above the floor must still render flat,
        // not get amplified into a fake wave.
        let decayedRef = -55 + AudioRecorder.meterReferenceHeadroomDB
        XCTAssertEqual(
            AudioRecorder.meterNorm(rmsDB: -52, referenceDB: decayedRef, noiseFloorDB: -55), 0)
    }

    func testQuieterSyllablesStayDynamic() {
        // 10 dB under the reference should read mid-range, not near-flat and
        // not near-max — the ^1.3 curve spreads syllable variation across the
        // bar range instead of compressing it at the top.
        let v = AudioRecorder.meterNorm(rmsDB: -30, referenceDB: -20, noiseFloorDB: -60)
        XCTAssertGreaterThan(v, 0.35)
        XCTAssertLessThan(v, 0.7)
    }

}
