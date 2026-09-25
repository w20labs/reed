import Foundation

private let dlog = Log(category: "denoise")

/// Best-effort local noise suppression for dictation, using a
/// bundled FastEnhancer Tiny (16kHz) ONNX model — see
/// docs/superpowers/specs/2026-08-14-fastenhancer-denoiser-design.md.
///
/// Never blocks a dictation: any failure to load the model or run inference
/// is logged and `process(wav:)` returns the input unchanged. Called from
/// the pipeline's denoise stage (Coordinator+Local.swift).
///
/// Inference itself (~11ms per second of audio, measured) runs synchronously
/// on the actor's own executor rather than being offloaded — it's fast
/// enough that hopping to another executor would cost more than it saves,
/// and this actor has exactly one caller.
/// Level staging for the denoise model.
///
/// FastEnhancer — like every speech enhancement model — is trained on speech
/// at ordinary recording levels. Reed hands it whatever the microphone
/// produced, and a quiet mic produces very quiet audio: real dictations
/// measured here peaked at **301 of 32767**, under 1% of full scale, RMS
/// around -50 dBFS. At that level the model classifies almost the whole
/// signal as noise and removes it — measured at 5.6-11.1 dB of attenuation
/// with only 6-20% of the 500-3000 Hz speech band surviving. The transcript
/// damage was real and reproducible: "my garage in Fremont" became "My Gorish
/// in France", "the best bodybuilder of its time" became "the best Loud in
/// his time".
///
/// So the audio is brought up to a normal level for inference and put back
/// exactly where it was afterwards. Restoring the gain matters: downstream
/// silence detection and the "Nothing to write" guard are level-sensitive, so
/// denoising must not quietly change how loud a recording appears.
enum DenoiseGain {
    /// Peak the model sees. ~-3 dBFS: loud enough to look like ordinary
    /// speech, with headroom so enhancement cannot clip.
    static let targetPeak: Float = 0.7
    /// Ceiling on the boost (~+42 dB). Past this the input is silence or a
    /// dead mic, and amplifying further only manufactures noise.
    static let maxGain: Float = 128
    /// Below this the recording carries no speech worth enhancing (~-80 dBFS).
    static let silenceFloor: Float = 1e-4

    /// The factor to apply before inference, or nil to skip denoising
    /// entirely because there is nothing there to clean.
    static func gain(forPeak peak: Float) -> Float? {
        guard peak > silenceFloor else { return nil }
        return min(maxGain, targetPeak / peak)
    }

    static func peak(of samples: [Float]) -> Float {
        samples.reduce(0) { Swift.max($0, Swift.abs($1)) }
    }
}

actor Denoiser {
    static let shared = Denoiser()

    /// What one call did. The app never fails on denoise — every outcome
    /// but `processed` and `skippedSilence` hands the raw audio on — but a
    /// bench must know (review 2026-09-08: under `swift test` no bundle
    /// exists, the model was never found, and every pipeline bench measured
    /// raw audio without saying so).
    enum Outcome: String, Equatable, Sendable {
        case processed, skippedSilence, emptyAudio, noModel, loadFailed, inferenceFailed
        /// The coordinator's stage gave up: the deadline passed, or the
        /// watchdog had already marked the denoiser wedged. Raw audio went on.
        case timedOut, watchdogBypassed
    }

    /// Test seam: sees EVERY outcome — each call's, and the coordinator
    /// stage's bypasses — so a bench can fail on any measured call that did
    /// not denoise, not only its warm-up probe (review 2026-09-08). nil in
    /// production.
    nonisolated(unsafe) static var outcomeObserverForTests: (@Sendable (Outcome) -> Void)?

    /// Report an outcome that happened outside `processReporting` (the
    /// coordinator stage's deadline and watchdog paths).
    nonisolated static func observe(_ outcome: Outcome) {
        outcomeObserverForTests?(outcome)
    }

    /// Injectable for tests — the real app resolves the bundled resource via
    /// `Bundle.main`, which finds nothing under `swift test` (no .app bundle
    /// exists there).
    private let modelURLProvider: () -> URL?
    private var model: DenoiserModel?
    /// Set on the first load/inference failure so a broken bundle doesn't
    /// retry (and re-log) on every single dictation.
    private var permanentlyDisabled = false
    private var disabledOutcome: Outcome = .noModel
    /// Test seam for the SHARED instance's model: the benches point it at
    /// the repo's `Resources/Models` file, which is what build-app.sh copies
    /// into the bundle. nil in production.
    nonisolated(unsafe) static var modelURLOverrideForTests: URL?

    init(modelURLProvider: @escaping () -> URL? = Denoiser.defaultModelURL) {
        self.modelURLProvider = modelURLProvider
    }

    static func defaultModelURL() -> URL? {
        if let override = modelURLOverrideForTests { return override }
        return Bundle.main.url(forResource: "fastenhancer_tiny_16k", withExtension: "onnx", subdirectory: "Models")
    }

    /// Forget the loaded model and any session-long disablement, so the
    /// next call resolves the model again — for a bench that installs the
    /// test seam after an earlier test already disabled the shared instance.
    func reload() {
        model = nil
        permanentlyDisabled = false
        disabledOutcome = .noModel
    }

    /// Denoises a 16kHz mono 16-bit WAV. Never throws.
    func process(wav: Data) -> Data {
        processReporting(wav: wav).audio
    }

    /// The same, with what happened.
    func processReporting(wav: Data) -> (audio: Data, outcome: Outcome) {
        let result = run(wav: wav)
        Self.observe(result.outcome)
        return result
    }

    private func run(wav: Data) -> (audio: Data, outcome: Outcome) {
        guard !permanentlyDisabled else { return (wav, disabledOutcome) }

        let model: DenoiserModel
        if let existing = self.model {
            model = existing
        } else {
            guard let url = modelURLProvider() else {
                dlog.error("denoise model not found in bundle — disabling for this session")
                permanentlyDisabled = true
                disabledOutcome = .noModel
                return (wav, .noModel)
            }
            do {
                model = try DenoiserModel(modelURL: url)
                self.model = model
            } catch {
                dlog.error("denoise session failed to load: \(error.localizedDescription) — disabling for this session")
                permanentlyDisabled = true
                disabledOutcome = .loadFailed
                return (wav, .loadFailed)
            }
        }

        let samples = WAVSamples.floatSamples(fromWAV: wav)
        guard !samples.isEmpty else { return (wav, .emptyAudio) }

        // Bring the level up for inference, then put it back. Without this a
        // quiet microphone gets its speech removed rather than its noise —
        // see DenoiseGain.
        let peak = DenoiseGain.peak(of: samples)
        guard let gain = DenoiseGain.gain(forPeak: peak) else {
            dlog.info("denoise skipped: peak \(peak) is below the silence floor")
            return (wav, .skippedSilence)
        }
        let staged = gain == 1 ? samples : samples.map { $0 * gain }

        do {
            let denoised = try model.denoise(samples: staged)
            let restored = gain == 1 ? denoised : denoised.map { $0 / gain }
            return (Self.wav(fromFloatSamples: restored), .processed)
        } catch {
            dlog.error("denoise inference failed: \(error.localizedDescription) — passing raw audio")
            return (wav, .inferenceFailed)
        }
    }

    /// Inverse of `WAVSamples.floatSamples(fromWAV:)` — normalized
    /// [-1, 1] float back to the 16kHz mono 16-bit WAV the speech model
    /// expects.
    private static func wav(fromFloatSamples samples: [Float]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var le = Int16(clamped * 32767).littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        return WAVWriter.wrap(pcm: pcm, sampleRate: 16_000, channels: 1, bitsPerSample: 16)
    }
}
