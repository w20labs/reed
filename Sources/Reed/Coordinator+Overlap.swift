import AppKit
import Foundation

/// Overlapped cleanup (latency step 2, 2026-08-27): while the user is still
/// speaking, every pause-delimited segment the recorder seals is
/// recognized and cleaned in the background; at release only the tail
/// segment is outstanding. Same stages as processLocal — denoise, ASR,
/// vocabulary, sentence cleanup — applied per segment; the visible behavior
/// is unchanged (nothing is injected before release), only the wait shrinks.
///
/// Flag `cleanup_overlap`, default ON since 2026-08-28 (kill switch:
/// `defaults write com.local.reed reed.flagOverride.cleanup_overlap -bool
/// false`). Measured before flipping: wait after release −77% on a
/// 16-sentence take and −84% on a 43 s run-on, everyday clips unchanged
/// (10/10 identical, equal time); what differs in the text is recognition
/// context at segment starts, and the breaks people notice at long pauses
/// are Whisper's own — single-pass makes them too (docs/bench/overlap_*).
extension Coordinator {
    static let overlapFlag = "cleanup_overlap"

    /// Called from start(): arm segmentation for this press when eligible.
    func armOverlapIfEnabled() {
        // Armed only when the engine is READY, not merely on disk (review
        // 2026-09-03, P2): segment workers bypass loadModelIfCold by design,
        // so a cold Parakeet would compile inside a segment — under the
        // "Transcribing" state and outside the model-load deadline. Cold
        // means single-pass: the release path loads it under the preparing
        // HUD, and the next press overlaps.
        guard FeatureFlags.shared.isEnabled(Self.overlapFlag, default: true),
              ParakeetClient.isReady else {
            recorder.disarmSegmenting()
            overlap.disarm()
            return
        }
        overlap.arm()
        // Generation-tagged (review 2026-08-30, R3): a seal notified late —
        // after this press ended — must never enqueue into the next press.
        let generation = pressGeneration
        recorder.armSegmenting { [weak self] in
            self?.drainSealedSegments(generation: generation)
        }
    }

    /// Take every waiting seal and give each its worker. Runs on the main
    /// actor: on the recorder's notification, and again from the release
    /// path with the seals stop() handed back.
    func drainSealedSegments(generation: Int) {
        guard generation == pressGeneration, overlap.isArmed else { return }
        enqueue(recorder.takeSealedSegments())
    }

    /// The press's collector is captured HERE, at the seal, and travels with
    /// the worker: a worker that ignores cancellation and finishes after the
    /// next press began must not read `review` then and find the next
    /// press's collector (review 2026-09-05, P1). Returns the workers, for
    /// tests that await a worker the session has already dropped.
    @discardableResult
    func enqueue(_ segments: [AudioRecorder.SealedSegment]) -> [Task<String?, Never>] {
        let collector = review
        return segments.compactMap { segment in
            let index = overlap.segmentCount
            let boundary: ReviewRecord.Boundary = segment.reason == .cap ? .cap : .pause
            return overlap.enqueue(sealedBy: segment.reason, range: segment.pcmRange) { [weak self] in
                await self?.cleanSegment(wav: segment.wav, rmsDB: segment.rmsDB, index: index, boundary: boundary,
                                         pcmRange: segment.pcmRange, into: collector)
            }
        }
    }

    /// Stop feeding segments — on release, cancel, or a press that never
    /// became a recording.
    func disarmOverlap() {
        recorder.disarmSegmenting()
        overlap.disarm()
    }

    /// Every exit that is not the release path (cancel, mic failure, the
    /// warming watchdog): no more tickles, no more seals, no workers left
    /// running for text nobody will read (R7, R12).
    func abortPress() {
        stopKeepWarm()
        disarmOverlap()
        overlap.reset()
        endReview()
    }

    /// One segment through the on-device stages. Touches no coordinator
    /// state (HUD, errors) — those belong to the release path. Nil on any
    /// failure, which makes the whole press fall back to single-pass.
    /// `index`/`boundary` name the segment for the local review copy, which
    /// is `collector` — captured by the caller before any await.
    func cleanSegment(wav: Data, rmsDB: Double, index: Int = 0, boundary: ReviewRecord.Boundary = .tail,
                      pcmRange: Range<Int>? = nil, into collector: DictationReview? = nil) async -> String? {
        do {
            // No loadModelIfCold here: it drives the HUD (.preparingModel)
            // and this runs while the user is still RECORDING. A download in
            // flight fails the segment (→ single-pass fallback, which
            // surfaces the proper error); a cold model is loaded silently by
            // transcribe() itself.
            try await failIfModelIsDownloading()
            let (denoised, _) = await denoiseStage(wav)
            let asrStart = Date()
            let raw = try await Self.transcribe(wav: denoised)
            let asrMs = Int(Date().timeIntervalSince(asrStart) * 1000)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // A silent or artifact segment contributes nothing — not a failure.
            guard !trimmed.isEmpty,
                  !SilenceArtifact.isArtifact(trimmed, rmsDB: rmsDB) else { return "" }
            let corrected = applyVocabCorrections(to: trimmed)
            return await reviewedCleanup(into: collector, segment: index, boundary: boundary, raw: trimmed, corrected: corrected,
                                         audioMs: max(0, (wav.count - 44) * 1000 / 32_000), asrMs: asrMs, pcmRange: pcmRange).text
        } catch {
            log.error("overlap segment failed: \(error.localizedDescription) — press will fall back to single-pass")
            return nil
        }
    }

    /// The release path when this press was overlapped: process the tail,
    /// await the sealed segments, assemble, inject. Falls back to
    /// processLocal on the FULL recording if anything failed.
    func processLocalOverlapped(wav: Data, context: DictationContext, stopped: AudioRecorder.StopResult) async {
        // Seals stop() handed back — sealed after the last notification was
        // handled — get their workers before anything else (R3).
        enqueue(stopped.pending)
        disarmOverlap()
        let sealedOffset = stopped.sealedOffset
        guard overlap.segmentCount > 0 else {
            abandonOverlapForSinglePass()
            await processLocal(wav: wav, context: context)
            return
        }
        let tailStart = min(44 + sealedOffset, wav.count)
        let pcmCount = max(0, wav.count - 44)
        let tailRange = min(sealedOffset, pcmCount)..<pcmCount
        let tailWav = WAVWriter.wrap(pcm: wav.subdata(in: tailStart..<wav.count),
                                     sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        // Everything still outstanding at release: the tail, plus whatever
        // head segments haven't finished yet. `outstanding` is the number
        // this whole design exists to shrink.
        let releaseWork = Date()
        let tail = await cleanSegment(wav: tailWav, rmsDB: recorder.lastRecordingRMSdB,
                                      index: overlap.segmentCount, boundary: .tail, pcmRange: tailRange, into: review)
        let tailSeconds = Date().timeIntervalSince(releaseWork)
        guard let tail, let heads = await overlap.collect() else {
            log.info("overlap: a segment failed — single-pass fallback on the full recording")
            // The heads and the tail recorded speculative segments and chunks;
            // single-pass is the real result (review 2026-09-04, P1).
            abandonOverlapForSinglePass()
            await processLocal(wav: wav, context: context)
            return
        }
        let outstandingSeconds = Date().timeIntervalSince(releaseWork)
        let segments = overlap.segmentCount
        let pieces = zip(heads, overlap.boundaries).map { Piece(text: $0, sealedBy: $1) } + [Piece(text: tail, sealedBy: nil)]
        let collector = review
        // Seam reading (flag, default OFF): the pause seams read from the
        // audio across each seal, before assembly decides them from text.
        var verdicts: [Int: SeamMark] = [:]
        var seamLine = ""
        if FeatureFlags.shared.isEnabled(SeamReading.flag, default: SeamReading.flagDefault) {
            let reads = await readSeams(pieces: pieces, ranges: overlap.ranges + [tailRange], pcm: wav.count > 44 ? wav.subdata(in: 44..<wav.count) : Data())
            verdicts = reads.verdicts
            seamLine = " · seam-read \(reads.verdicts.count)/\(reads.verdicts.count + reads.undecided.count + reads.unread) \(reads.readMs)ms"
        }
        // Bound for assembly too: a re-clean across a pause is a chunk of this dictation.
        let text = await LocalCleanup.$observer.withValue(collector) {
            await Self.assembleSegments(pieces, verdicts: verdicts) { index, decision in collector?.join(segment: index, decision: decision) }
        }
        overlap.reset()
        guard !text.isEmpty else {
            state = .notice("Nothing to write")
            DebugTimings.persist("DROP empty-asr(overlap) wav=\(wav.count) | \(recorder.lastStopStats)")
            recordLocalDictation(ok: false, stage: "empty", context: context)
            endReview()
            return
        }
        lastTranscript = text
        state = .injecting
        let receipt = injector.inject(text)
        let totalSeconds = Date().timeIntervalSince(context.releaseAt)
        let counts = deliverReview(injection: receipt, timings: .init(totalSeconds: totalSeconds, tailSeconds: tailSeconds,
                                                                     outstandingSeconds: outstandingSeconds), audio: wav)
        let line = String(format: "total %.1fs · overlap %d+1 seg · tail %.1fs · outstanding %.1fs",
                          totalSeconds, segments, tailSeconds, outstandingSeconds)
            + " · asr·\(engineLabel)" + (keepWarmTickles > 0 ? " · warm \(keepWarmTickles)" : "")
            + (counts.map { " · \($0.summary)" } ?? "") + seamLine
            + " · " + injector.lastReport
        log.notice("local dictation timings: \(line)")
        DebugTimings.persist(line)
        if DebugTimings.enabled { lastTimings = line }
        recordLocalDictation(ok: true, stage: nil, context: context, text: text,
                             asrSeconds: tailSeconds, cleanSeconds: outstandingSeconds - tailSeconds, counts: counts)
        finishDictation()
    }
}
