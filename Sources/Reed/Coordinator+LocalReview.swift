import AppKit
import Foundation

/// The local-review collector's hooks into a press (P16, DECIDED
/// 2026-09-04). Content is kept only while the developer key is set; the
/// content-free counts are produced for every local dictation and ride
/// the timings line and the analytics event.
extension Coordinator {
    /// At the press: one collector per local dictation. It is never stored
    /// anywhere global — the cleanup loop sees it only through a task-local
    /// bound around each segment's cleanup (`reviewedCleanup`) and around
    /// assembly. Every worker takes its collector as a value captured
    /// BEFORE its first await (`enqueue`), never by reading `review` after
    /// one: a worker that outlives this press keeps writing into this
    /// collector, which nobody reads, never into the next one.
    func beginReview() {
        review = DictationReview(keepsContent: LocalReviewFlag.isEnabled)
    }

    /// At every exit — delivered, dropped, failed, cancelled.
    func endReview() {
        review = nil
    }

    /// The overlap path gave up; single-pass is about to run on the full
    /// recording. Everything recorded so far was speculative, and the
    /// workers that recorded it are cancelled, not awaited — a late one may
    /// still report a chunk. So the collector is REPLACED, not cleared: the
    /// late workers hold the old one, which nobody reads; single-pass gets
    /// a fresh one for the same dictation (review 2026-09-05, P1).
    func abandonOverlapForSinglePass() {
        overlap.reset()
        guard let old = review else { return }
        review = DictationReview(keepsContent: old.keepsContent, startedAt: old.startedAt)
    }

    /// Clean one segment's text under its review span, recording what was
    /// heard, what cleanup was given, timings, and which path ran. A path
    /// that never asks the model (tier off / basic, AI unavailable, the
    /// fast path) is recorded as one not-attempted chunk, so the default
    /// path is measured too. Same output as a bare `LocalCleanup.applyWithPath`.
    /// `collector` is the caller's, captured before its first await.
    func reviewedCleanup(into collector: DictationReview?, segment index: Int, boundary: ReviewRecord.Boundary,
                         raw: String, corrected: String,
                         audioMs: Int? = nil, asrMs: Int? = nil, pcmRange: Range<Int>? = nil) async -> LocalCleanup.Outcome {
        collector?.segment(index, boundary: boundary, raw: raw, corrected: corrected, audioMs: audioMs, asrMs: asrMs, pcmRange: pcmRange)
        let outcome = await LocalCleanup.$observer.withValue(collector) {
            await LocalCleanup.$chunkSpan.withValue([index]) {
                await LocalCleanup.applyWithPath(to: corrected)
            }
        }
        collector?.cleanupOutcome(segment: index, path: outcome.path.rawValue, reason: outcome.reason)
        collector?.delivered(segment: index, text: outcome.text)
        if let collector, !collector.sawChunks(for: index) {
            collector.notAttempted(segment: index, text: outcome.text, reason: Self.notAttemptedReason(outcome))
        }
        return outcome
    }

    /// Why the model was never asked, from the outcome the tier produced.
    static func notAttemptedReason(_ outcome: LocalCleanup.Outcome) -> String {
        switch outcome.path {
        case .raw: return "tier-off"
        case .basic: return outcome.reason == "ai-unavailable" ? "ai-unavailable" : "tier-basic"
        case .fast: return "fast-path"
        case .ai: return "no-chunks"
        }
    }

    /// At delivery: close the record (saved only when content was kept) and
    /// hand back the counts for the timings line and the analytics event.
    /// `injection` is the injector's receipt — the sanitized string that
    /// reached the destination, and where. `audio` is the recording (the
    /// full WAV the pipeline ran on), kept beside the copy — only while the
    /// key is set, like every other content.
    func deliverReview(injection: TextInjector.Receipt, timings: ReviewRecord.Timings, audio: Data? = nil) -> CleanupCounts? {
        guard let review else { return nil }
        let delivery = DictationReview.Delivery(
            injection: .init(text: injection.text, target: injection.target, method: injection.method),
            timings: timings,
            // "localOnly": the one pipeline, under the name the QA tooling
            // (scripts/qa/local_review.py) and older records already carry.
            mode: "localOnly", engine: engineLabel,
            flags: [
                LocalCleanup.coalesceFlag: FeatureFlags.shared.isEnabled(LocalCleanup.coalesceFlag, default: true),
                LocalCleanup.fragmentGlueFlag: FeatureFlags.shared.isEnabled(LocalCleanup.fragmentGlueFlag, default: true),
                SeamRules.flag: FeatureFlags.shared.isEnabled(SeamRules.flag, default: SeamRules.flagDefault)
            ])
        let record = review.finish(delivery)
        if review.keepsContent { LocalReviewStore.save(record, audio: audio) }
        return record.counts
    }
}
