import Foundation

/// One dictation's collector (P16). Bound to the press's tasks as the
/// cleanup loop's observer (`LocalCleanup.observer`, a TASK-LOCAL — never
/// a process-global: a cancelled overlap worker that ignores cancellation
/// and finishes after the next press began still writes into ITS OWN
/// dictation's collector, which nobody reads, review 2026-09-04 P1). Fed by
/// the coordinator (segments, seams, delivery) and by the cleanup loop
/// (chunks, attempts, outcomes). Segments are cleaned concurrently, so the
/// loop's calls are attributed through `LocalCleanup.chunkSpan`, bound
/// around each segment's cleanup.
///
/// Content (raw, proposals, typed text) is retained only when
/// `keepsContent` is true — the review key is set. The content-free
/// `CleanupCounts` are kept either way.
final class DictationReview: CleanupObserver, @unchecked Sendable {
    let id = UUID().uuidString
    let startedAt: Date
    let keepsContent: Bool

    private let lock = NSLock()
    private var segments: [Int: ReviewRecord.Segment] = [:]
    private var openChunks: [[Int]: OpenChunk] = [:]
    private var chunks: [ReviewRecord.Chunk] = []
    private(set) var counts = CleanupCounts()

    private struct OpenChunk {
        var input: String
        var repairHint: String?
        var attempts: [ReviewRecord.Attempt] = []
    }

    init(keepsContent: Bool, startedAt: Date = Date()) {
        self.keepsContent = keepsContent
        self.startedAt = startedAt
    }

    private func keep(_ text: String) -> String { keepsContent ? text : "" }
    private func keep(_ text: String?) -> String? { keepsContent ? text : nil }

    // MARK: - Fed by the coordinator

    /// A segment's recognizer output and what cleanup was given.
    func segment(_ index: Int, boundary: ReviewRecord.Boundary, raw: String, corrected: String,
                 audioMs: Int? = nil, asrMs: Int? = nil, pcmRange: Range<Int>? = nil) {
        lock.lock(); defer { lock.unlock() }
        var seg = segments[index] ?? ReviewRecord.Segment(index: index, boundary: boundary, raw: "", corrected: "")
        seg.boundary = boundary
        seg.raw = keep(raw)
        seg.corrected = keep(corrected)
        seg.audioMs = audioMs
        seg.asrMs = asrMs
        seg.pcmStart = pcmRange?.lowerBound
        seg.pcmEnd = pcmRange?.upperBound
        segments[index] = seg
    }

    /// The segment's cleaned text as handed to assembly.
    func delivered(segment index: Int, text: String) {
        lock.lock(); defer { lock.unlock() }
        var seg = segments[index] ?? ReviewRecord.Segment(index: index, boundary: .tail, raw: "", corrected: "")
        seg.delivered = keep(text)
        segments[index] = seg
    }

    /// Which cleanup path ran for a segment (raw / basic / fast / AI) and why.
    func cleanupOutcome(segment index: Int, path: String, reason: String?) {
        lock.lock(); defer { lock.unlock() }
        var seg = segments[index] ?? ReviewRecord.Segment(index: index, boundary: .tail, raw: "", corrected: "")
        seg.cleanupPath = path
        seg.cleanupReason = reason
        segments[index] = seg
    }

    /// The model was never asked about this segment's text (tier off or
    /// basic, AI unavailable, the fast path): one chunk, counted, so the
    /// common default path is measured too (review 2026-09-04, P1).
    func notAttempted(segment index: Int, text: String, reason: String) {
        lock.lock(); defer { lock.unlock() }
        chunks.append(ReviewRecord.Chunk(segments: [index], input: keep(text), repairHint: nil, attempts: [],
                                         delivered: keep(text), outcome: .notAttempted, reason: reason))
        counts.chunks += 1
        counts.notAttempted[reason, default: 0] += 1
    }

    /// Whether the cleanup loop reported any chunk for this segment.
    func sawChunks(for index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return chunks.contains { $0.segments.contains(index) }
    }

    /// What assembly did at the seam before segment `index`.
    func join(segment index: Int, decision: ReviewRecord.JoinDecision) {
        lock.lock(); defer { lock.unlock() }
        var seg = segments[index] ?? ReviewRecord.Segment(index: index, boundary: .pause, raw: "", corrected: "")
        seg.joinedBy = decision
        segments[index] = seg
        switch decision {
        case .sentenceEnd: counts.seamsSentenceEnd += 1
        case .gluedBreath: counts.seamsGluedBreath += 1
        case .capSeam: counts.seamsCapSeam += 1
        case .recleanedAcrossCue: counts.seamsRecleaned += 1
        case .absorbed: counts.seamsAbsorbed += 1
        case .restartCollapsed: counts.seamsRestart += 1
        case .seamPeriod, .seamComma, .seamNothing: counts.seamsRuled += 1
        }
    }

    // MARK: - CleanupObserver (fed by LocalCleanup.cleanLine)

    private var currentSpan: [Int] { LocalCleanup.chunkSpan ?? [-1] }

    func chunkStarted(input: String, repairHint: String?) {
        lock.lock(); defer { lock.unlock() }
        openChunks[currentSpan] = OpenChunk(input: keep(input), repairHint: repairHint)
    }

    func attempt(_ attempt: ReviewRecord.Attempt) {
        lock.lock(); defer { lock.unlock() }
        var kept = attempt
        kept.proposal = keep(attempt.proposal)
        openChunks[currentSpan, default: OpenChunk(input: "")].attempts.append(kept)
    }

    func chunkDelivered(_ text: String, outcome: ReviewRecord.ChunkOutcome, reason: String?) {
        lock.lock(); defer { lock.unlock() }
        let span = currentSpan
        let open = openChunks.removeValue(forKey: span) ?? OpenChunk(input: "")
        chunks.append(ReviewRecord.Chunk(segments: span, input: open.input, repairHint: open.repairHint,
                                         attempts: open.attempts, delivered: keep(text), outcome: outcome, reason: reason))
        counts.chunks += 1
        if open.attempts.count > 1 { counts.retried += 1 }
        for attempt in open.attempts {
            if let rejection = attempt.gateRejection { counts.rejections[rejection, default: 0] += 1 }
            if let failure = attempt.failure { counts.failures[failure, default: 0] += 1 }
        }
        switch outcome {
        case .modelAccepted: counts.modelAccepted += 1
        case .rulesAfterRejection: counts.rulesAfterRejection += 1
        case .modelFailed: counts.modelFailed += 1
        case .rulesOnly: counts.rulesOnly += 1
        case .budgetSkipped: counts.budgetSkipped += 1
        case .notAttempted: counts.notAttempted[reason ?? "unknown", default: 0] += 1
        }
    }

    // MARK: - Delivery

    struct Delivery {
        var injection: ReviewRecord.Injection
        var timings: ReviewRecord.Timings
        var mode: String
        var engine: String
        var flags: [String: Bool] = [:]
    }

    /// The record for this dictation. Text fields are empty unless the
    /// review key was set when the press began; the counts are always real.
    /// Chunks are ordered by their first segment, then by arrival — a
    /// stable order, since `sorted` alone is not.
    func finish(_ delivery: Delivery, at deliveredAt: Date = Date()) -> ReviewRecord {
        lock.lock(); defer { lock.unlock() }
        return ReviewRecord(
            id: id, startedAt: startedAt, deliveredAt: deliveredAt,
            mode: delivery.mode, engine: delivery.engine,
            targetBundleID: keep(delivery.injection.target), injectionMethod: delivery.injection.method,
            versions: .init(app: LocalReviewVersions.app, prompt: LocalReviewVersions.prompt,
                            gate: LocalReviewVersions.gate, schema: LocalReviewVersions.schema, flags: delivery.flags),
            segments: segments.keys.sorted().compactMap { segments[$0] },
            chunks: chunks.enumerated()
                .sorted { ($0.element.segments.first ?? -1, $0.offset) < ($1.element.segments.first ?? -1, $1.offset) }
                .map(\.element),
            finalText: keep(delivery.injection.text), timings: delivery.timings, counts: counts, reference: nil)
    }
}
