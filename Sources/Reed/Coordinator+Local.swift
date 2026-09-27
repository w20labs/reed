import AppKit
import Foundation

/// Safety-net cap on on-device transcription. Normal dictations transcribe well
/// under this; only a genuinely wedged model reaches it, at which point we
/// surface an error rather than spin the HUD forever.
private let asrTimeout: TimeInterval = 30
/// Separate, generous cap for a COLD model load — post-download CoreML/ANE
/// specialization measured ~59 s in the Round-1 bench, so the load must never
/// count against the 30 s transcription deadline (it read as "Transcription
/// timed out" on the first dictation after a download).
private let modelLoadTimeout: TimeInterval = 180
/// Bound on the denoise step — best-effort by design (see `Denoiser`), so a
/// timeout here just means falling back to the raw, un-denoised audio, never
/// a dictation failure. Generous relative to measured inference cost
/// (~11ms per second of audio) — this guards against an actual ONNX Runtime
/// hang, not normal-case latency.
private let denoiseTimeout: TimeInterval = 5

// DenoiseWatchdog and DebugTimings live in LocalASR/LocalPipelineSupport.swift.

extension Coordinator {
    /// Best-effort denoise with the wedge watchdog. Returns the audio to
    /// transcribe — the input unchanged on any failure or timeout, never an
    /// error — plus the stage's wall-clock seconds.
    func denoiseStage(_ wav: Data) async -> (Data, Double) {
        let start = Date()
        let denoised: Data
        if DenoiseWatchdog.shared.isWedged() {
            Denoiser.observe(.watchdogBypassed)
            denoised = wav
        } else if let result = try? await withDeadline(denoiseTimeout, {
            await Denoiser.shared.process(wav: wav)
        }) {
            denoised = result
        } else {
            DenoiseWatchdog.shared.markWedged()
            Denoiser.observe(.timedOut)
            denoised = wav
        }
        return (denoised, Date().timeIntervalSince(start))
    }
    /// The pipeline: on-device ASR, then text injection. No network —
    /// GateURLProtocol guarantees it.
    func processLocal(wav: Data, context: DictationContext) async {
        var loadSeconds: Double?
        do {
            // Cold model? Load it OUTSIDE the transcription deadline, with its
            // own HUD state so the spinner reads as preparation, not a hang.
            // (Prewarm on launch/mode-select makes this path rare.) Only when
            // the model is on disk — a missing model must keep hitting
            // `transcribe`'s .notInstalled error, never a surprise download.
            try await failIfModelIsDownloading()
            do {
                loadSeconds = try await loadModelIfCold()
            } catch is TimeoutError {
                activeError = .generic(
                    headline: "Speech model couldn't load",
                    detail: "The on-device model didn't finish preparing. Please try again.",
                    raw: "local ASR: model load timed out")
                state = .error(activeError?.headline ?? "Speech model couldn't load")
                return
            }
            let (denoisedWav, denoiseSeconds) = await denoiseStage(wav)
            let asrStart = Date()
            let raw = try await withDeadline(asrTimeout) {
                // Denoised audio (main) into the recognizer.
                try await Self.transcribe(wav: denoisedWav)
            }
            let asrSeconds = Date().timeIntervalSince(asrStart)
            let content = raw
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Audio was captured but ASR heard nothing — the soft notice
                // pill, not an error (silence is not a failure) and never
                // silent idle (reads as "it ate my sentence").
                log.info("local ASR produced empty body")
                state = .notice("Nothing to write")
                DebugTimings.persist("DROP empty-asr wav=\(wav.count) | \(recorder.lastStopStats)")
                return
            }
            if SilenceArtifact.isArtifact(content, rmsDB: recorder.lastRecordingRMSdB) {
                log.info("local ASR returned a silence artifact")
                state = .notice("Nothing to write")
                DebugTimings.persist("DROP silence-artifact wav=\(wav.count) | \(recorder.lastStopStats)")
                return
            }
            // Built-in vocabulary pass (spec 2026-08-19): deterministic
            // spoken-forms formatter + curated term correction, between ASR
            // and the LLM — the only stage allowed to substitute words.
            let correctedContent = applyVocabCorrections(to: content)
            let cleanStart = Date()
            // The path that actually RAN, not the configured tier — "on-device
            // AI 0.0s" (fast path) read as a lie in the pill. One call returns
            // text + path + trigger, so label and routing can't drift. The
            // whole recording is the review copy's one segment (a tail).
            let cleaned = await reviewedCleanup(into: review, segment: 0, boundary: .tail, raw: content, corrected: correctedContent, audioMs: context.recMs, asrMs: Int(asrSeconds * 1000), pcmRange: 0..<max(0, wav.count - 44))
            let text = cleaned.text
            // The routing reason rides the timings line when it carries
            // information (gate rejections, spent budget, structural repair —
            // "always" is the uneventful default). Field failure 2026-08-26:
            // a raw-looking dictation was undiagnosable from the log because
            // the reason was computed and then dropped.
            var cleanupLabel = cleaned.path.label
            if let reason = cleaned.reason, reason != "always" {
                cleanupLabel += " (\(reason))"
            }
            let cleanSeconds = Date().timeIntervalSince(cleanStart)
            lastTranscript = text
            state = .injecting
            let receipt = injector.inject(text)
            // The number the user actually feels: hotkey release → text pasted
            // (stop/flush + load + ASR + cleanup + injection).
            let totalSeconds = Date().timeIntervalSince(context.releaseAt)
            let timings = ReviewRecord.Timings(totalSeconds: totalSeconds, loadSeconds: loadSeconds, denoiseSeconds: denoiseSeconds,
                                               asrSeconds: asrSeconds, cleanupSeconds: cleanSeconds)
            let counts = deliverReview(injection: receipt, timings: timings, audio: wav)
            let line = DebugTimings.line(
                total: totalSeconds, load: loadSeconds, denoise: denoiseSeconds, asr: asrSeconds,
                clean: cleanSeconds, tier: cleanupLabel, engine: engineLabel, warm: keepWarmTickles)
                + (counts.map { " · \($0.summary)" } ?? "")
                + " · " + injector.lastReport
            // Persist to Reed's own timings file — this Mac's logd retains
            // nothing from the app (verified), so we keep our own numbers-only
            // history for "it felt slow yesterday" forensics.
            log.notice("local dictation timings: \(line)")
            DebugTimings.persist(line)
            if DebugTimings.enabled { lastTimings = line }
            finishDictation()
        } catch {
            log.error("local pipeline failed: \(error.localizedDescription)")
            activeError = localError(for: error)
            state = .error(activeError?.headline ?? "On-device transcription failed")
            endReview()
        }
    }

    /// Runs the built-in vocabulary pass. The audit note is CONTENT-FREE
    /// (finding 2026-08-25): reed.log rides support reports whose UI promises
    /// "no transcripts", so the note names rules, domains, and patterns —
    /// never the substituted words themselves.
    func applyVocabCorrections(to content: String) -> String {
        let result = corrections.apply(content)
        guard !result.substitutions.isEmpty || !result.formattedSpans.isEmpty else {
            return content
        }
        log.info("vocab pass: \(Self.vocabAuditNote(result))")
        return result.text
    }

    /// Pure + content-free, e.g. "subs=2 [engineering/always, general/always] spans=[email]".
    static func vocabAuditNote(_ result: CorrectionResult) -> String {
        var parts: [String] = []
        if !result.substitutions.isEmpty {
            let kinds = result.substitutions.map { "\($0.domain.rawValue)/\($0.rule)" }.sorted()
            parts.append("subs=\(result.substitutions.count) [\(kinds.joined(separator: ", "))]")
        }
        if !result.formattedSpans.isEmpty {
            let patterns = result.formattedSpans.map(\.pattern).sorted()
            parts.append("spans=[\(patterns.joined(separator: ", "))]")
        }
        return parts.joined(separator: " ")
    }

    /// Cold model? Load it OUTSIDE the transcription deadline, with its own HUD
    /// state so the spinner reads as preparation rather than a hang. (Prewarm on
    /// launch/mode-select makes this path rare.) Only when the model is on disk —
    /// a missing model must keep hitting `transcribe`'s .notInstalled error,
    /// never a surprise download.
    ///
    /// Returns how long the load took, or nil when the model was already warm.
    /// `TimeoutError` propagates: processLocal maps it to the load-specific
    /// error. (Until 2026-08-26 this was shared with the hybrid pipeline —
    /// keep it factored this way so a future second caller can't drift.)
    func loadModelIfCold() async throws -> Double? {
        // P15 (DECIDED 2026-09-02): the one model. Missing on disk is never
        // a surprise download inside a dictation — the download controller
        // runs it with the onboarding progress flow, and this dictation
        // surfaces "still downloading" (localError). Present but cold: load
        // it here, outside the deadline, under the preparing HUD. A load
        // failure is a visible error, never a swap to another engine.
        guard ModelStore.isSpeechModelInstalled else {
            await MainActor.run { ModelDownloadController.shared.repairIfNeeded() }
            throw SpeechModelError.notInstalled
        }
        guard await !ParakeetClient.isReady else { return nil }
        state = .preparingModel
        let start = Date()
        try await withDeadline(modelLoadTimeout) { try await ParakeetClient.shared.prepare() }
        state = .transcribing
        return Date().timeIntervalSince(start)
    }

    /// A download in flight is NOT something to join from inside a dictation —
    /// that is what raced HubApi's shared temp file and broke onboarding
    /// (2026-08-12). Throwing `.notInstalled` hands it to `localError`, which
    /// turns it into "still downloading — N%" off the progress that very
    /// download is already publishing.
    func failIfModelIsDownloading() async throws {
        // The test seam replaces the engine: with it set there is no model
        // to wait for, whatever the download controller is doing.
        if Self.transcribeOverride != nil { return }
        // The controller's download (onboarding, or the launch repair)
        // owns the progress the error line reads.
        if await ModelDownloadController.shared.isDownloading {
            throw SpeechModelError.notInstalled
        }
    }

    /// Why on-device dictation cannot run right now, or nil when it can:
    /// the speech model is downloading, its download failed, its files are
    /// missing (the repair is kicked here), or this Mac cannot run it. Read
    /// at the hotkey press (nothing captured) and on the release path (the
    /// notInstalled error), so both tell the same story (review 2026-09-03).
    func speechModelRefusal() -> DictationError? {
        let download = ModelDownloadController.shared
        switch download.phase {
        case .downloading:
            // The percent rides the headline so it's visible in the HUD
            // pill, not just the menu banner's detail.
            return .generic(
                headline: download.isPreparing
                    ? "Preparing the speech model"
                    : "Speech model still downloading - \(Int(download.fraction * 100))%",
                detail: download.hudProgressLine ?? "",
                raw: "local ASR: model downloading")
        case .failed(let message):
            return .generic(
                headline: "The speech model didn't download",
                detail: message + " Try again from the Reed menu.",
                raw: "local ASR: model download failed")
        case .idle:
            guard !ModelStore.isSpeechModelInstalled else { return nil }
            // Files gone: start the repair (idempotent), and say so.
            download.repairIfNeeded()
            return .generic(
                headline: "Getting the speech model",
                detail: "Reed is fetching its on-device speech model. Dictation works as soon as it's ready.",
                raw: "local ASR: model not installed")
        }
    }

    private func localError(for error: Error) -> DictationError {
        if error is TimeoutError {
            return .generic(
                headline: "Transcription timed out",
                detail: "The on-device model took too long to respond. Please try again.",
                raw: "local ASR: timed out")
        }
        if case SpeechModelError.notInstalled = error {
            return speechModelRefusal() ?? .generic(
                headline: "Getting the speech model",
                detail: "Reed is fetching its on-device speech model. Dictation works as soon as it's ready.",
                raw: "local ASR: model not installed")
        }
        return .generic(
            headline: "On-device transcription failed",
            detail: "Something went wrong running the local model. Try again.",
            raw: "\(error)")
    }
}
