import Foundation

/// Peak and RMS of a captured int16 PCM buffer, in dBFS.
///
/// Extracted from `AudioRecorder.stop()`: it is pure arithmetic over a byte
/// buffer with no dependence on the engine, so it belongs outside the recorder
/// and can be tested directly — which matters, because this is what decides
/// whether a dictation is treated as silence and thrown away.
struct RecordingLevels: Equatable {
    let peakDB: Double
    let rmsDB: Double
    let sampleCount: Int

    /// Digital silence and an empty buffer both report -120 dBFS, the same
    /// floor the rest of the audio code uses for "nothing there at all".
    static let floorDB = -120.0

    static func measure(pcm: Data) -> RecordingLevels {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        var peak: Int32 = 0
        var sumSquares: Double = 0
        pcm.withUnsafeBytes { raw in
            guard let samples = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for index in 0..<sampleCount {
                let value = Int32(samples[index])
                peak = max(peak, abs(value))
                sumSquares += Double(value) * Double(value)
            }
        }
        let rms = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        return RecordingLevels(
            peakDB: peak > 0 ? 20 * log10(Double(peak) / 32768.0) : floorDB,
            rmsDB: rms > 0 ? 20 * log10(rms / 32768.0) : floorDB,
            sampleCount: sampleCount
        )
    }
}
