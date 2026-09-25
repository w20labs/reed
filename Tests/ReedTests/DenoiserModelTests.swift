import XCTest
@testable import Reed

final class DenoiserModelTests: XCTestCase {
    /// The bundled Tiny 16kHz FastEnhancer model, resolved via this source
    /// file's own location rather than Bundle.main — `swift test` produces
    /// no .app bundle, so Bundle.main.url(forResource:) (what the real app
    /// uses, see Denoiser.defaultModelURL) finds nothing here. Not private:
    /// DenoiserTests (Task 3) reuses this.
    static let modelURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/ReedTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources/Models/fastenhancer_tiny_16k.onnx")
    }()

    func testResourceIsBundledAtExpectedSize() throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: Self.modelURL.path)
        XCTAssertEqual(
            attrs[.size] as? Int, 125_233,
            "fastenhancer_tiny_16k.onnx changed size — was it swapped for a different model?")
    }

    func testDenoisePreservesSampleCount() throws {
        let model = try DenoiserModel(modelURL: Self.modelURL)
        let samples = Self.syntheticNoisyTone(seconds: 0.5)
        let out = try model.denoise(samples: samples)
        XCTAssertEqual(out.count, samples.count)
    }

    func testDenoiseReducesNoiseEnergy() throws {
        let model = try DenoiserModel(modelURL: Self.modelURL)
        let noisy = Self.syntheticNoisyTone(seconds: 1.0)
        let out = try model.denoise(samples: noisy)
        XCTAssertLessThan(Self.rms(out), Self.rms(noisy),
            "denoised RMS should be lower than the noisy input's RMS")
    }

    func testEmptyInputReturnsEmptyOutput() throws {
        let model = try DenoiserModel(modelURL: Self.modelURL)
        XCTAssertEqual(try model.denoise(samples: []), [])
    }

    /// Deterministic (seeded) 220Hz tone + uniform noise, matching the
    /// fixture the design spike verified against (input RMS ≈ 0.2288,
    /// output RMS ≈ 0.1971 for 1.0s).
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static func syntheticNoisyTone(seconds: Double) -> [Float] {
        let sampleRate: Float = 16_000
        let count = Int(seconds * Double(sampleRate))
        var rng = SeededGenerator(seed: 42)
        return (0..<count).map { i in
            let tone = 0.3 * sin(2 * Float.pi * 220 * Float(i) / sampleRate)
            let noise = Float.random(in: -0.15...0.15, using: &rng)
            return tone + noise
        }
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
    }
}
