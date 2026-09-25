import XCTest
@testable import Reed

/// The denoiser was removing speech instead of noise on quiet microphones —
/// measured at 5.6–11.1 dB of attenuation with as little as 6% of the
/// 500–3000 Hz speech band surviving. These pin the level staging that fixes it.
final class DenoiseGainTests: XCTestCase {
    func testQuietInputIsBroughtUpToTheModelsLevel() throws {
        // A real dictation from this machine peaked at 301/32767.
        let peak = Float(301) / 32767
        let gain = try XCTUnwrap(DenoiseGain.gain(forPeak: peak))
        XCTAssertEqual(peak * gain, DenoiseGain.targetPeak, accuracy: 0.001,
                       "quiet audio should arrive at the model at the target level")
        XCTAssertGreaterThan(gain, 50, "that recording needs a substantial boost")
    }

    func testLoudInputIsBroughtDownRatherThanLeftToClip() throws {
        let gain = try XCTUnwrap(DenoiseGain.gain(forPeak: 1.0))
        XCTAssertLessThan(gain, 1, "already-hot audio should be attenuated, not amplified")
        XCTAssertEqual(1.0 * gain, DenoiseGain.targetPeak, accuracy: 0.001)
    }

    func testBoostIsCapped() throws {
        // Just above the silence floor: without a cap this would multiply by
        // ~7000 and turn a dead mic's noise into a signal.
        let gain = try XCTUnwrap(DenoiseGain.gain(forPeak: DenoiseGain.silenceFloor * 1.01))
        XCTAssertEqual(gain, DenoiseGain.maxGain, accuracy: 0.001)
    }

    func testSilenceSkipsDenoisingAltogether() {
        XCTAssertNil(DenoiseGain.gain(forPeak: 0), "digital silence has nothing to clean")
        XCTAssertNil(DenoiseGain.gain(forPeak: DenoiseGain.silenceFloor * 0.5))
    }

    func testPeakIgnoresSign() {
        XCTAssertEqual(DenoiseGain.peak(of: [0.1, -0.9, 0.3]), 0.9, accuracy: 1e-6)
        XCTAssertEqual(DenoiseGain.peak(of: []), 0)
    }
}
