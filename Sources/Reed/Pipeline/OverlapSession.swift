import Foundation

/// Per-press bookkeeping for overlapped cleanup (latency step 2,
/// 2026-08-27): as the recorder seals pause-delimited segments, each one is
/// handed to a worker task immediately — recognition + cleanup run while the
/// user keeps talking. At release the coordinator awaits them IN ORDER,
/// appends the tail segment, and injects one text.
///
/// Serial by design: Foundation Models serializes concurrent sessions
/// anyway (lever 1, docs/bench/fm_concurrency.txt), so workers chain
/// through `previous` — each starts when the one before it finishes. That
/// keeps ordering trivial and the ANE/GPU never oversubscribed.
///
/// Failure is sticky: if any segment's worker fails (model unavailable,
/// recognizer error) the whole press falls back to the single-pass path on
/// the full recording, so overlap can only ever be faster, never lossier.
@MainActor
final class OverlapSession {
    /// One sealed segment's worker: its cleaned text, or nil on failure.
    private var workers: [Task<String?, Never>] = []
    /// Why each enqueued segment was sealed, parallel to `workers`.
    private(set) var boundaries: [SpeechSegmenter.Reason] = []
    /// Each segment's PCM byte range in the recording, parallel to
    /// `workers`; nil when the caller did not know it (seam reading).
    private(set) var ranges: [Range<Int>?] = []
    private var previous: Task<String?, Never>?
    /// True from press until release while this press is being overlapped.
    private(set) var isArmed = false
    /// Wall-clock the first segment was sealed, for the timings line.
    private(set) var firstSealAt: Date?

    func arm() {
        reset()
        isArmed = true
    }

    func disarm() {
        isArmed = false
    }

    func reset() {
        workers.forEach { $0.cancel() }
        workers = []
        boundaries = []
        ranges = []
        previous = nil
        firstSealAt = nil
        isArmed = false
    }

    var segmentCount: Int { workers.count }

    /// Enqueue one sealed segment's work. `work` runs after the previous
    /// segment's work completes, never concurrently with it. `sealedBy`
    /// records how the segment ended so assembly can tell a sentence
    /// boundary (pause) from a mid-sentence cap cut. Returns the worker
    /// (nil when not armed) so a test can await one the session dropped.
    @discardableResult
    func enqueue(sealedBy: SpeechSegmenter.Reason = .pause, range: Range<Int>? = nil,
                 _ work: @escaping @Sendable () async -> String?) -> Task<String?, Never>? {
        guard isArmed else { return nil }
        boundaries.append(sealedBy)
        ranges.append(range)
        if firstSealAt == nil { firstSealAt = Date() }
        let prior = previous
        let task = Task<String?, Never> {
            _ = await prior?.value
            return await work()
        }
        workers.append(task)
        previous = task
        return task
    }

    /// Await every segment's text, in order. Nil if any segment failed —
    /// the caller then falls back to the single-pass path.
    func collect() async -> [String]? {
        var out: [String] = []
        for task in workers {
            guard let text = await task.value else { return nil }
            out.append(text)
        }
        return out
    }
}
