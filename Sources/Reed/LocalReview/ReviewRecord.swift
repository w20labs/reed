import Foundation

/// One dictation's review copy (P16). Text, and — since 2026-09-06, for
/// the corpus bench — the recording as a WAV beside it (`audioFile`).
/// Written by `LocalReviewStore` only while `LocalReviewFlag` is set.
struct ReviewRecord: Codable, Equatable {
    struct Versions: Codable, Equatable {
        var app: String
        var prompt: String
        var gate: String
        var schema: Int
        var flags: [String: Bool]
    }

    /// Why the recorder sealed a segment. `tail` is the audio left at
    /// release (and the whole recording when overlap was off).
    enum Boundary: String, Codable {
        case pause, cap, tail
    }

    /// What assembly did at the seam BEFORE this segment.
    enum JoinDecision: String, Codable {
        /// Kept the recognizer's sentence end (a pause read as a boundary).
        case sentenceEnd
        /// Glued as a breath: the head ended in a word no sentence ends in.
        case gluedBreath
        /// A cap cut: the pre-roll's duplicate trimmed and the halves rejoined.
        case capSeam
        /// The next piece opened with a correction cue; both sides re-cleaned.
        case recleanedAcrossCue
        /// The next piece vanished into the seam (all of it was duplicate).
        case absorbed
        /// A restart split across the pause: the head's abandoned start went.
        case restartCollapsed
        /// A seam verdict (decision 1) read the pause as a sentence end.
        case seamPeriod
        /// …as a clause break: a comma, the next's capital lowered.
        case seamComma
        /// …as nothing: one run of words across the pause.
        case seamNothing
    }

    struct Segment: Codable, Equatable {
        var index: Int
        var boundary: Boundary
        /// What the recognizer heard.
        var raw: String
        /// After the vocabulary pass — what cleanup was given.
        var corrected: String
        /// The segment's audio length and how long recognition took.
        var audioMs: Int?
        var asrMs: Int?
        /// The segment's byte range in the recording's PCM (schema 6): the
        /// live seal points, so a bench reads a seam where the app sealed
        /// it, not where a replay would. Absent on older copies.
        var pcmStart: Int?
        var pcmEnd: Int?
        /// The segment's cleaned text exactly as assembly received it
        /// (schema 6): lines, fragment rejoins and all — a bench must not
        /// rebuild it from the chunks (review 2026-09-10, #5).
        var delivered: String?
        /// The cleanup path that ran for this segment (raw / basic / fast /
        /// on-device AI) and its routing reason.
        var cleanupPath: String?
        var cleanupReason: String?
        var joinedBy: JoinDecision?
    }

    enum AttemptKind: String, Codable {
        case generic, repair
    }

    /// One model call and what became of its proposal.
    struct Attempt: Codable, Equatable {
        var kind: AttemptKind
        /// The model's proposal; nil when the call failed or returned nothing.
        var proposal: String?
        /// "accepted" · "gate:<reason>" (the gate refused it) · "unfaithful"
        /// (the recall backstop refused it) · "failed:<class>" (timeout /
        /// error / empty) — every attempt carries exactly one.
        var verdict: String
        var seconds: Double

        var gateRejection: String? { verdict.hasPrefix("gate:") ? String(verdict.dropFirst(5)) : nil }
        var failure: String? { verdict.hasPrefix("failed:") ? String(verdict.dropFirst(7)) : nil }
    }

    /// How a chunk's delivered text was reached.
    enum ChunkOutcome: String, Codable {
        case modelAccepted
        case rulesAfterRejection
        case modelFailed
        case rulesOnly
        case budgetSkipped
        /// The model was never asked: tier off / basic, AI unavailable, or
        /// the fast path (`reason` says which).
        case notAttempted
    }

    struct Chunk: Codable, Equatable {
        /// The recorder segments this chunk spans (one; two for a re-clean
        /// across a pause).
        var segments: [Int]
        /// The chunk as the model received it (post-vocabulary, chunked).
        var input: String
        var repairHint: String?
        var attempts: [Attempt]
        var delivered: String
        var outcome: ChunkOutcome
        /// For `modelFailed`: the failure class; for `notAttempted`: why.
        var reason: String?
    }

    struct Timings: Codable, Equatable {
        var totalSeconds: Double
        var loadSeconds: Double?
        var denoiseSeconds: Double?
        var asrSeconds: Double?
        var cleanupSeconds: Double?
        var tailSeconds: Double?
        var outstandingSeconds: Double?
    }

    /// Set by a human on the QA page, never by the app.
    struct Reference: Codable, Equatable {
        var text: String
        var setBy: String
        var setAt: Date
        var edited: Bool
    }

    /// What actually reached the destination: the sanitized string the
    /// injector typed or pasted, where, and by which path.
    struct Injection: Codable, Equatable {
        var text: String
        var target: String?
        var method: String
    }

    var id: String
    var startedAt: Date
    var deliveredAt: Date
    var mode: String
    var engine: String
    var targetBundleID: String?
    var injectionMethod: String?
    var versions: Versions
    var segments: [Segment]
    var chunks: [Chunk]
    /// The text as injected (sanitized), not the pipeline's pre-injection string.
    var finalText: String
    /// The recording (16 kHz mono int16 WAV) beside this copy, by file name
    /// — same folder, permissions and expiry; replayed by the corpus bench.
    /// nil when no audio was kept.
    var audioFile: String?
    var timings: Timings
    var counts: CleanupCounts
    var reference: Reference?
}

/// Content-free counts for one dictation — computed on every Mac, with or
/// without the review key; they ride the timings line and, under consent,
/// the analytics dictation event. Counts, never one status: one dictation
/// can carry accepted, rejected, failed and budget-skipped chunks at once.
struct CleanupCounts: Codable, Equatable {
    var chunks = 0
    var modelAccepted = 0
    var rulesAfterRejection = 0
    var modelFailed = 0
    var rulesOnly = 0
    var budgetSkipped = 0
    /// Chunks the model was never asked about, by reason (tier-off,
    /// tier-basic, ai-unavailable, fast-path) — the common default path.
    var notAttempted: [String: Int] = [:]
    /// Second attempts (the generic prompt after a refused repair).
    var retried = 0
    /// Gate rejections by reason (`CleanupGate.Rejection.rawValue`).
    var rejections: [String: Int] = [:]
    /// Model failures by class (timeout / error / empty), per attempt.
    var failures: [String: Int] = [:]
    var seamsSentenceEnd = 0
    var seamsGluedBreath = 0
    var seamsCapSeam = 0
    var seamsRecleaned = 0
    var seamsAbsorbed = 0
    var seamsRestart = 0
    /// Pause seams a seam verdict decided (`SeamRules`).
    var seamsRuled = 0

    init() {}

    /// Older copies (schema ≤ 3) lack the counts added since; every count
    /// decodes with its default so a copy on disk stays readable by the
    /// corpus bench whatever schema wrote it (2026-09-06).
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        chunks = try values.decodeIfPresent(Int.self, forKey: .chunks) ?? 0
        modelAccepted = try values.decodeIfPresent(Int.self, forKey: .modelAccepted) ?? 0
        rulesAfterRejection = try values.decodeIfPresent(Int.self, forKey: .rulesAfterRejection) ?? 0
        modelFailed = try values.decodeIfPresent(Int.self, forKey: .modelFailed) ?? 0
        rulesOnly = try values.decodeIfPresent(Int.self, forKey: .rulesOnly) ?? 0
        budgetSkipped = try values.decodeIfPresent(Int.self, forKey: .budgetSkipped) ?? 0
        notAttempted = try values.decodeIfPresent([String: Int].self, forKey: .notAttempted) ?? [:]
        retried = try values.decodeIfPresent(Int.self, forKey: .retried) ?? 0
        rejections = try values.decodeIfPresent([String: Int].self, forKey: .rejections) ?? [:]
        failures = try values.decodeIfPresent([String: Int].self, forKey: .failures) ?? [:]
        seamsSentenceEnd = try values.decodeIfPresent(Int.self, forKey: .seamsSentenceEnd) ?? 0
        seamsGluedBreath = try values.decodeIfPresent(Int.self, forKey: .seamsGluedBreath) ?? 0
        seamsCapSeam = try values.decodeIfPresent(Int.self, forKey: .seamsCapSeam) ?? 0
        seamsRecleaned = try values.decodeIfPresent(Int.self, forKey: .seamsRecleaned) ?? 0
        seamsAbsorbed = try values.decodeIfPresent(Int.self, forKey: .seamsAbsorbed) ?? 0
        seamsRestart = try values.decodeIfPresent(Int.self, forKey: .seamsRestart) ?? 0
        seamsRuled = try values.decodeIfPresent(Int.self, forKey: .seamsRuled) ?? 0
    }

    /// The timings-line suffix: "cleanup a3 r1(unlicensed-deletion×1) f0 o0 b0 n1(tier-basic) · seams e2 g1 c0 x0 a0 r0",
    /// plus " v1" once a seam verdict was applied (decision 1).
    var summary: String {
        var parts = ["cleanup a\(modelAccepted) r\(rulesAfterRejection)\(Self.breakdown(rejections)) f\(modelFailed)\(Self.breakdown(failures)) o\(rulesOnly) b\(budgetSkipped) n\(notAttempted.values.reduce(0, +))\(Self.breakdown(notAttempted))"]
        if retried > 0 { parts[0] += " retry\(retried)" }
        let seams = seamsSentenceEnd + seamsGluedBreath + seamsCapSeam + seamsRecleaned + seamsAbsorbed + seamsRestart + seamsRuled
        if seams > 0 {
            parts.append("seams e\(seamsSentenceEnd) g\(seamsGluedBreath) c\(seamsCapSeam) x\(seamsRecleaned) a\(seamsAbsorbed) r\(seamsRestart)"
                         + (seamsRuled > 0 ? " v\(seamsRuled)" : ""))
        }
        return parts.joined(separator: " · ")
    }

    private static func breakdown(_ table: [String: Int]) -> String {
        guard !table.isEmpty else { return "" }
        return "(" + table.keys.sorted().map { "\($0)×\(table[$0] ?? 0)" }.joined(separator: ",") + ")"
    }

    /// Flat, content-free properties for the analytics event.
    var analyticsProperties: [String: Int] {
        var props: [String: Int] = [
            "cleanup_chunks": chunks, "cleanup_accepted": modelAccepted,
            "cleanup_rejected": rulesAfterRejection, "cleanup_failed": modelFailed,
            "cleanup_rules_only": rulesOnly, "cleanup_budget_skipped": budgetSkipped,
            "cleanup_not_attempted": notAttempted.values.reduce(0, +), "cleanup_retried": retried,
            "seams_sentence_end": seamsSentenceEnd, "seams_glued": seamsGluedBreath,
            "seams_cap": seamsCapSeam, "seams_recleaned": seamsRecleaned, "seams_absorbed": seamsAbsorbed,
            "seams_restart": seamsRestart, "seams_ruled": seamsRuled
        ]
        for (reason, count) in rejections { props["gate_\(Self.key(reason))"] = count }
        for (reason, count) in failures { props["model_\(Self.key(reason))"] = count }
        for (reason, count) in notAttempted { props["skip_\(Self.key(reason))"] = count }
        return props
    }

    private static func key(_ reason: String) -> String {
        String(reason.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}
