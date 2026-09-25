import Foundation

/// The recorder's 16 kHz mono int16 WAV as normalized floats — what the
/// speech model (FluidAudio) and the denoiser consume.
enum WAVSamples {
    /// Skips the 44-byte header. No resampling: the recorder already
    /// produces 16 kHz.
    static func floatSamples(fromWAV data: Data) -> [Float] {
        guard data.count > 44 else { return [] }
        let pcm = data.subdata(in: 44..<data.count)
        let count = pcm.count / MemoryLayout<Int16>.size
        return pcm.withUnsafeBytes { raw -> [Float] in
            let ints = raw.bindMemory(to: Int16.self)
            return (0..<count).map { Float(Int16(littleEndian: ints[$0])) / 32768.0 }
        }
    }
}

/// Why on-device dictation cannot run: the speech model is not on disk, or
/// its download is still in flight (`localError` turns this into the
/// "still downloading" line off the controller's progress).
enum SpeechModelError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "The on-device speech model isn't downloaded yet."
        }
    }
}
