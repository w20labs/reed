import Foundation

/// What the cleanup loop tells a per-dictation collector (P16): each chunk
/// as the model receives it, every model attempt with its verdict, and how
/// the chunk's delivered text was reached. Behaviour is untouched when no
/// observer is bound.
protocol CleanupObserver: AnyObject, Sendable {
    func chunkStarted(input: String, repairHint: String?)
    func attempt(_ attempt: ReviewRecord.Attempt)
    func chunkDelivered(_ text: String, outcome: ReviewRecord.ChunkOutcome, reason: String?)
}

extension LocalCleanup {
    /// The collector for the dictation whose task this is — a task-local,
    /// bound by the coordinator around each segment's cleanup and around
    /// assembly. A worker that outlives its press keeps its own binding and
    /// can never write into the next press's collector (review 2026-09-04).
    @TaskLocal static var observer: CleanupObserver?
    /// The recorder segments the current cleanup call belongs to (one; two
    /// for a re-clean across a pause). nil = outside any segment.
    @TaskLocal static var chunkSpan: [Int]?

    /// What one model call came back with: text, or the failure class
    /// (timeout / error / empty / unavailable) OF THAT CALL. Concurrent
    /// segment workers each hold their own; nothing is shared (review
    /// 2026-09-05, P2).
    enum ModelReply: Equatable, Sendable {
        case text(String)
        case failed(String)

        var text: String? { if case .text(let text) = self { return text } else { return nil } }
        var failure: String? { if case .failed(let failure) = self { return failure } else { return nil } }
        var timedOut: Bool { failure?.hasPrefix("timeout") ?? false }
    }

    /// Test seam (never set by the app): stands in for the on-device model
    /// so the attempt/gate/outcome bookkeeping can be exercised on any Mac,
    /// including one without the model.
    nonisolated(unsafe) static var modelCallOverrideForTests: (@Sendable (String, Bool) async -> ModelReply)?

    /// One model attempt on a chunk: call, faithfulness backstop, gate —
    /// with a typed verdict, so a failure belongs to the attempt that had
    /// it and never leaks onto a later chunk (review 2026-09-04, P2).
    enum AttemptVerdict: Equatable {
        case accepted
        case gateRejected(CleanupGate.Rejection)
        case unfaithful
        case failed(String)
    }

    struct AttemptResult {
        let proposal: String?
        let verdict: AttemptVerdict

        var accepted: String? { verdict == .accepted ? proposal : nil }
        var gate: CleanupGate.Rejection? { if case .gateRejected(let rejection) = verdict { return rejection } else { return nil } }
        var failure: String? { if case .failed(let failure) = verdict { return failure } else { return nil } }
        var label: String {
            switch verdict {
            case .accepted: return "accepted"
            case .gateRejected(let rejection): return "gate:\(rejection.rawValue)"
            case .unfaithful: return "unfaithful"
            case .failed(let failure): return "failed:\(failure)"
            }
        }
    }

    static func modelAttempt(chunk: String, repair: Bool) async -> AttemptResult {
        let start = Date()
        let result: AttemptResult
        switch await modelCall(chunk, repair: repair) {
        case .text(let proposal) where proposal.isEmpty:
            result = AttemptResult(proposal: nil, verdict: .failed("empty"))
        case .text(let proposal):
            if !looksFaithful(input: chunk, output: proposal, minRecall: 0.5, maxGrowth: 3) {
                result = AttemptResult(proposal: proposal, verdict: .unfaithful)
            } else if let gate = CleanupGate.rejection(input: chunk, output: proposal, repairHint: repair) {
                result = AttemptResult(proposal: proposal, verdict: .gateRejected(gate))
            } else {
                result = AttemptResult(proposal: proposal, verdict: .accepted)
            }
        case .failed(let failure):
            // The failure came back WITH this call's reply.
            result = AttemptResult(proposal: nil, verdict: .failed(failure))
        }
        observer?.attempt(.init(kind: repair ? .repair : .generic, proposal: result.proposal,
                                verdict: result.label, seconds: Date().timeIntervalSince(start)))
        return result
    }

    private static func modelCall(_ chunk: String, repair: Bool) async -> ModelReply {
        if let override = modelCallOverrideForTests { return await override(chunk, repair) }
        if #available(macOS 26.0, *) { return await AICleanup.clean(chunk, repair: repair) }
        return .failed("unavailable")
    }
}
