import FluidAudio
import Foundation

/// The speech recognizer: NVIDIA Parakeet via FluidAudio on the Neural
/// Engine (lever 3 spike 2026-08-13, the one model since P15). The variant
/// is a debug-flag string so the bench can compare more than one without a
/// rebuild:
///
///   defaults write com.local.reed reed.debugParakeet -string v3   # v2 | v3 | ctc110m
///   defaults delete com.local.reed reed.debugParakeet             # back to the default (v3)
enum ParakeetFlag {
    static let key = "reed.debugParakeet"

    /// Trial notes (2026-08-13/14): `ctc110m` won the benchmark round — best
    /// stress-set WER of all six engines (3.6% against large-v3's 9.5%),
    /// lowest RTF, smallest download. Switched to `v3` on 2026-08-14 for a
    /// week of real-world use: not the leader on read prose (3.56% against
    /// v2's 2.12%) but far better where dictation actually fails — names,
    /// jargon, technical terms (4.5% against v2's 10.4% and large-v3's 9.5%)
    /// — and the variant whose remaining errors custom vocabulary can
    /// address, which large-v3 has no mechanism for.
    ///
    /// Lever 3 (2026-08-29, docs/bench/asr_engines.txt, p1_run4_*): on the
    /// corpus v3 recognizes in 116 ms at 2.8% WER against large-v3's 986 ms
    /// at 5.8%; end to end p50 1.81 → 0.91 s. **v3 is the default from
    /// 2026-08-29.** P15 (DECIDED 2026-09-02): it is the ONE model — onboarding
    /// downloads it. WhisperKit left the dictation path then and the
    /// repository on 2026-09-06; there is no engine to pin "off" to.
    ///
    ///   defaults write com.local.reed reed.debugParakeet -string v2   # v2 | ctc110m
    static let defaultVariant = "v3"
    /// Every variant the client can load. The one list the benches validate
    /// against too (review 2026-09-01): an unknown name used to load v3 and
    /// report its numbers under the made-up label, ungated.
    static let supportedVariants: Set<String> = ["v3", "v2", "ctc110m"]

    /// The variant to run. An unknown persisted value (the retired "off"
    /// pin included) is the default variant — the model that would load
    /// anyway — so the label the app reports is the model that actually ran.
    static var variant: String {
        guard let raw = UserDefaults.standard.string(forKey: key), !raw.isEmpty else { return defaultVariant }
        return supportedVariants.contains(raw) ? raw : defaultVariant
    }
}

/// The speech recognizer. Downloads once (onboarding's Download button, or
/// the launch-time repair when the files went missing), loads on demand,
/// and reports progress across BOTH the bytes and the first CoreML compile
/// so the UI can draw one bar (P15).
actor ParakeetClient {
    static let shared = ParakeetClient()

    private var manager: AsrManager?
    private var loadedVariant: String?
    private let plog = Log(category: "parakeet")

    /// Whether the selected variant is loaded and can transcribe now.
    /// Read from the main actor (dictation start) without hopping onto the
    /// ASR actor: a dictation that starts while Parakeet is still loading
    /// shows the preparing HUD rather than queueing behind the load.
    @MainActor private(set) static var isReady = false

    /// The single in-flight `prepare()` — actors are re-entrant, and two
    /// callers (onboarding's Download, the launch prewarm, a dictation's
    /// cold load) must never run two downloads of the same files at once.
    /// Everyone awaits one task; only the first caller's progress is
    /// reported, since a follower is not the one drawing a bar.
    private var prepareTask: Task<Void, Error>?
    private var prepareGeneration = 0
    /// Bumped by every `unload()`. A prepare that was suspended in the
    /// download or the CoreML load when an unload came through must not
    /// commit its result afterwards — an unload racing a load (the benches
    /// unload between engines) used to end with the model resident and
    /// "ready" again (review 2026-09-03, P2).
    private var loadGeneration = 0
    var isPreparing: Bool { prepareTask != nil }
    /// Test seam (never set by the app): awaited between the CoreML load and
    /// the commit, so a test can land an `unload()` in that window.
    static var afterLoadForTests: (@Sendable () async -> Void)?

    /// (fraction 0…1, compiling) — `compiling` is FluidAudio's CoreML phase
    /// after the bytes, when the fraction stops meaning "downloaded".
    typealias Progress = @Sendable (Double, Bool) -> Void

    static func version(for variant: String) -> AsrModelVersion {
        switch variant {
        case "v2": return .v2
        case "ctc110m": return .tdtCtc110m
        default: return .v3
        }
    }

    /// Where FluidAudio keeps a variant's files.
    static func modelDirectory(for variant: String) -> URL {
        AsrModels.defaultCacheDirectory(for: version(for: variant))
    }

    /// Pure disk check — every required file present, no network.
    static func isInstalled(variant: String) -> Bool {
        AsrModels.modelsExist(at: modelDirectory(for: variant), version: version(for: variant))
    }

    /// Download (if missing) + load, coalesced. Throws on a failed download or
    /// load; a `CancellationError` when `cancelPrepare()` was called.
    func prepare(progress: Progress? = nil) async throws {
        // The work runs in its own task below, which does NOT inherit the
        // caller's cancellation — a caller retired before it got here must
        // not start a load nobody wants (review 2026-09-04, P2).
        try Task.checkCancellation()
        let variant = ParakeetFlag.variant
        if manager != nil, loadedVariant == variant { return }
        if let inFlight = prepareTask {
            if !inFlight.isCancelled { return try await inFlight.value }
            // A CANCELLED task is still mid-flight: FluidAudio's download has
            // no cancellation point inside a file, so it keeps writing until
            // that file lands. Starting a second download alongside it is the
            // exact corruption the earlier engine's client learned to avoid
            // (2026-08-12). Let it settle first; its failure is not ours.
            _ = try? await inFlight.value
            if manager != nil, loadedVariant == variant { return }
        }
        let task = Task { try await self.performPrepare(variant: variant, progress: progress) }
        prepareGeneration &+= 1
        let generation = prepareGeneration
        prepareTask = task
        defer { if generation == prepareGeneration { prepareTask = nil } }
        try await task.value
    }

    /// Stops an in-flight download (onboarding's Cancel). The model is never
    /// left half-loaded: a cancelled prepare commits nothing.
    func cancelPrepare() {
        prepareTask?.cancel()
    }

    private func performPrepare(variant: String, progress: Progress?) async throws {
        if manager != nil, loadedVariant == variant { return }
        if manager != nil {
            // A variant switch means a different model entirely — drop the old one
            // rather than leaving two sets of weights resident.
            manager = nil
            loadedVariant = nil
            await MainActor.run { Self.isReady = false }
        }
        try Task.checkCancellation()
        let generation = loadGeneration
        plog.info("loading parakeet \(variant)")
        let handler: ProgressHandler? = progress.map { report in
            { update in
                var compiling = false
                if case .compiling = update.phase { compiling = true }
                report(update.fractionCompleted, compiling)
            }
        }
        let models = try await AsrModels.downloadAndLoad(version: Self.version(for: variant), progressHandler: handler)
        try Task.checkCancellation()
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        // Test seam: lets a test interleave an unload exactly here, where a
        // real prepare is suspended when a mode switch lands.
        if let hook = Self.afterLoadForTests { await hook() }
        try Task.checkCancellation()
        // An unload came through while this was suspended: the caller no
        // longer wants a model resident. Commit nothing; the loaded
        // instance just deallocates.
        guard generation == loadGeneration else {
            plog.info("parakeet \(variant) loaded after an unload — discarded")
            throw CancellationError()
        }
        manager = asr
        loadedVariant = variant
        // "Ready" means proven to load, not merely downloaded — onboarding's
        // Continue and the launch repair both read this record.
        ModelStore.markSpeechModelLoaded(variant: variant)
        await MainActor.run { Self.isReady = true }
        plog.info("parakeet \(variant) ready")
    }

    /// Transcribe a finished 16 kHz mono int16 recording. Audio beyond
    /// ~20 s is cut at quiet points and transcribed piece by piece
    /// (LongAudioChunker) — the engine is unreliable on longer inputs.
    func transcribe(wav: Data) async throws -> String {
        if Self.recognizerOverride == nil { try await prepare() }
        guard manager != nil || Self.recognizerOverride != nil, wav.count > 44 else { return "" }
        let pcm = wav.subdata(in: 44..<wav.count)
        let pieces = LongAudioChunker.pieces(pcm: pcm)
        if pieces.count > 1 {
            plog.info("long audio: \(String(format: "%.1f", Double(pcm.count) / 32_000))s cut into \(pieces.count) pieces")
        }
        var texts: [String] = []
        for piece in pieces {
            let text = try await transcribePiece(pcm.subdata(in: piece.range))
            guard !text.isEmpty else { continue }
            // A cap-cut seam: drop the pre-roll's duplicate and the
            // completion the recognizer invented at the truncated end
            // (Coordinator.trimOverlap, the overlapped path's rule).
            if piece.opensAtCapCut, let head = texts.last {
                // The overlapped path's whole seam rule (review 2026-08-30,
                // R9): trim the duplicate, then join textually — the head's
                // invented period goes, the next half's capital is lowered
                // when nothing was trimmed.
                let seam = Coordinator.trimOverlap(head: head, next: text)
                guard !seam.next.isEmpty else { continue }
                texts[texts.count - 1] = Coordinator.joinAcrossCut(seam.head, seam.next, lowercaseFirst: seam.removed == 0)
                continue
            }
            texts.append(text)
        }
        return texts.joined(separator: " ")
    }

    /// Test seam: replaces the model call itself (never the policy around
    /// it), so `transcribe(wav:)` is testable without models.
    nonisolated(unsafe) static var recognizerOverride: ((Data) async throws -> String)?

    /// One piece (≤ ~20 s): the slice as cut, and — `SecondReading` — once
    /// more with the prefix when the first reading collapsed.
    private func transcribePiece(_ pcm: Data) async throws -> String {
        let enabled = await MainActor.run { FeatureFlags.shared.isEnabled(SecondReading.flag, default: SecondReading.flagDefault) }
        let selection = try await SecondReading.read(pcm, enabled: enabled) { try await self.recognizePiece($0) }
        if selection.replaced {
            plog.notice("second reading kept: \(selection.alternateWords ?? 0) words over \(selection.originalWords) (\(pcm.count / 32) ms slice)")
        }
        return selection.text
    }

    /// The model call for one piece, verbatim — no chunking, no policy.
    /// Internal so a bench can read a piece exactly as `transcribePiece`
    /// does, prefixed reading included (review 2026-09-08: a prefixed
    /// slice sent through `transcribe(wav:)` instead can cross the
    /// chunker's threshold and be cut into pieces production never makes).
    func recognizePiece(_ pcm: Data) async throws -> String {
        if let override = Self.recognizerOverride { return try await override(pcm) }
        guard let manager else { return "" }
        let samples = WAVSamples.floatSamples(fromWAV: WAVWriter.wrap(pcm: pcm, sampleRate: 16_000, channels: 1, bitsPerSample: 16))
        guard !samples.isEmpty else { return "" }
        // The decoder state carries context across chunks in streaming use.
        // Reed hands over one complete utterance, so it starts fresh every
        // time — otherwise one dictation would prime the next.
        //
        // The layer count is NOT fixed at 2: the 110M hybrid has a 1-layer
        // prediction network, and a default-constructed state fails inside
        // CoreML with "MultiArray shape (2 x 1 x 640) does not match
        // (1 x 1 x 640)". Ask the manager what the loaded model actually
        // wants rather than assuming.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        // Pin the decode to English (v3 only; ignored by v2/110M). v3 is
        // multilingual and, unconstrained, occasionally emits whole
        // utterances in Cyrillic — "make an X dot com post" came out
        // "Мейка экс дотком пост" (field, 2026-08-16/19). The hint makes the
        // decoder skip top-K tokens whose script doesn't match. Revisit when
        // Reed ships beyond en-US.
        let result = try await manager.transcribe(samples, decoderState: &state, language: .english)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop the model from memory (mode switch / engine switch). Also
    /// retires any prepare in flight: it may still be downloading or
    /// compiling, and when it resumes it finds the generation moved on and
    /// commits nothing.
    func unload() async {
        loadGeneration &+= 1
        prepareTask?.cancel()
        manager = nil
        loadedVariant = nil
        await MainActor.run { Self.isReady = false }
    }
}
