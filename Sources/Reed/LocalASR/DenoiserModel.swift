import Foundation
import OnnxRuntimeBindings

enum DenoiserError: LocalizedError {
    case missingOutput(String)
    case shortOutput

    var errorDescription: String? {
        switch self {
        case .missingOutput(let name): return "ONNX Runtime output '\(name)' missing"
        case .shortOutput: return "ONNX Runtime returned fewer samples than expected"
        }
    }
}

/// Pure signal-processing wrapper around one loaded FastEnhancer ONNX
/// session: feed it normalized [-1, 1] float samples at 16kHz, get back the
/// same number of denoised samples. Stateless across calls — each
/// `denoise(samples:)` call runs its own zero-initialized cache through the
/// whole clip in one batch, exactly like the reference `scripts/test_onnx.py`
/// in the FastEnhancer repo (github.com/aask1357/fastenhancer). No WAV,
/// Bundle, or fallback concerns here — see `Denoiser` for those.
final class DenoiserModel {
    /// Fixed by the checkpoint (`fastenhancer_t.onnx`, DNS-trained 16kHz
    /// Tiny release), not configurable: `wav_in`'s ONNX shape is `[1, 256]`
    /// (hop size), and the reference script's n_fft default is 512.
    private static let hopSize = 256
    private static let nFFT = 512
    /// The four `cache_in_N` shapes read directly off the ONNX graph.
    private static let cacheShapes: [[NSNumber]] = [
        [1, 256], [1, 256], [1, 16, 20], [1, 16, 20],
    ]

    private let env: ORTEnv
    private let session: ORTSession

    init(modelURL: URL) throws {
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        // Tiny model, hundreds of ~256-sample calls per clip — a thread
        // pool costs more than it saves at this size.
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
    }

    /// Denoises `samples` (normalized [-1, 1] mono float @ 16kHz) and
    /// returns the same number of samples back, clipped to [-1, 1]. Empty
    /// input returns empty output. Throws on any ONNX Runtime failure —
    /// callers decide the fallback (see `Denoiser`).
    func denoise(samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        let length = samples.count
        var padded = samples
        padded.append(contentsOf: repeatElement(0, count: Self.nFFT))

        var cache = try Self.cacheShapes.map { shape -> ORTValue in
            let count = shape.reduce(1) { $0 * $1.intValue }
            return try makeValue(Array(repeating: Float(0), count: count), shape: shape)
        }
        let outputNames = Set(["wav_out"] + (0..<cache.count).map { "cache_out_\($0)" })

        var outChunks: [[Float]] = []
        var idx = 0
        while idx < length + Self.nFFT - Self.hopSize {
            let chunk = Array(padded[idx..<idx + Self.hopSize])
            let wavIn = try makeValue(chunk, shape: [1, NSNumber(value: Self.hopSize)])

            var inputs: [String: ORTValue] = ["wav_in": wavIn]
            for (i, value) in cache.enumerated() { inputs["cache_in_\(i)"] = value }

            let outputs = try session.run(withInputs: inputs, outputNames: outputNames, runOptions: nil)

            guard let wavOut = outputs["wav_out"] else { throw DenoiserError.missingOutput("wav_out") }
            outChunks.append(try floats(from: wavOut))

            cache = try (0..<cache.count).map { i -> ORTValue in
                guard let cacheOut = outputs["cache_out_\(i)"] else {
                    throw DenoiserError.missingOutput("cache_out_\(i)")
                }
                return cacheOut
            }
            idx += Self.hopSize
        }

        let full = outChunks.flatMap { $0 }
        let start = Self.nFFT - Self.hopSize
        let end = start + length
        guard full.count >= end else { throw DenoiserError.shortOutput }
        return full[start..<end].map { max(-1, min(1, $0)) }
    }

    private func makeValue(_ floatValues: [Float], shape: [NSNumber]) throws -> ORTValue {
        var floatValues = floatValues
        let data = NSMutableData(bytes: &floatValues, length: floatValues.count * MemoryLayout<Float>.size)
        return try ORTValue(tensorData: data, elementType: .float, shape: shape)
    }

    private func floats(from value: ORTValue) throws -> [Float] {
        let nsData = try value.tensorData()
        let data = nsData as Data
        return data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            Array(ptr.bindMemory(to: Float.self))
        }
    }
}
