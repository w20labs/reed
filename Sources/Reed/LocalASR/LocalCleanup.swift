import Foundation

// `LocalCleanupTier` lives in LocalCleanupTier.swift.
enum LocalCleanup {
    static let tierKey = "localCleanupTier"

    static var tier: LocalCleanupTier {
        LocalCleanupTier(rawValue: UserDefaults.standard.string(forKey: tierKey) ?? "") ?? .basic
    }

    static func setTier(_ tier: LocalCleanupTier) {
        UserDefaults.standard.set(tier.rawValue, forKey: tierKey)
    }

    /// Which stage actually produced the output. Returned by `applyWithPath`
    /// alongside the text, so the HUD/timings label and the usage log come
    /// from the same value that routed — they can't drift.
    enum Path: String {
        case raw, basic, fast, ai
        var label: String {
            switch self {
            case .raw: return "raw"
            case .basic: return "basic"
            case .fast: return "fast"
            case .ai: return "on-device AI"
            }
        }
    }

    /// One cleanup application: the text plus which stage produced it and —
    /// when the AI tier was engaged — which needsAI rule routed there.
    struct Outcome {
        let text: String
        let path: Path
        let reason: String?
    }

    static func apply(to text: String) async -> String {
        await applyWithPath(to: text).text
    }

    /// Apply the selected tier. AI degrades to Basic automatically when the
    /// system model is unavailable or errors — so the pipeline never blocks.
    ///
    /// Rules-first (2026-08-14): the deterministic pass runs BEFORE the
    /// routing decision. `BasicCleanup.clean` + `close` fix the two most
    /// common triggers — bare fillers and an open final sentence — in ~0 ms,
    /// so the ~1.5 s on-device model is only paid for what still shows
    /// disfluency signals afterwards (self-corrections, asides, run-ons, and
    /// the phrases Basic deliberately won't touch, like a bare "you know",
    /// which needs the model's judgement to tell tic from content).
    static func applyWithPath(to text: String) async -> Outcome {
        guard !text.isEmpty else { return Outcome(text: text, path: .raw, reason: nil) }
        if tier == .off { return Outcome(text: text, path: .raw, reason: nil) }
        // An end-of-sentence value correction, resolved by rule before either
        // tier: the model keeps the abandoned option there (TailCorrection).
        let text = TailCorrection.apply(text)
        switch tier {
        case .off:
            return Outcome(text: text, path: .raw, reason: nil)
        case .basic:
            return Outcome(text: BasicCleanup.clean(text), path: .basic, reason: nil)
        case .ai:
            guard #available(macOS 26.0, *), AICleanup.isAvailable else {
                // Checkbox on, but Apple Intelligence is off or ineligible:
                // Settings › Cleanup carries the amber "not enabled" banner;
                // dictations degrade to the rules pass, honestly labelled.
                return Outcome(text: BasicCleanup.close(BasicCleanup.clean(text)),
                               path: .basic, reason: "ai-unavailable")
            }
            // Founder decision 2026-08-19: checkbox on + model available =
            // the model cleans EVERY dictation — the disfluency-signal gate
            // (the "fast path") is retired; predictable output beats the
            // saved milliseconds.
            //
            // Cleaned PER SENTENCE (same day): the identical prompt fixes
            // "Um is can I trying to understand…" as a lone sentence and
            // fails inside a 40-word transcript — quality decays with input
            // length from the second sentence on. SentenceChunker keeps
            // cross-sentence corrections together ("…Bob. Wait, no, Alice.").
            // Structural detection runs per chunk with one job: picking the
            // repair prompt for confirmed-broken speech — it fixes what the
            // generic prompt leaves untouched, but over-repairs clean prose,
            // so it must never see that.
            return await aiOutcome(text)
        }
    }

    /// Aggregate wall-clock budget for the model across ONE dictation's
    /// chunks (review 2026-08-26): each call has its own 8 s deadline
    /// (AICleanup.timeout), but nothing bounded the SUM — a max-length
    /// recording can hold dozens of sentences, and the hotkey is dead while
    /// `.transcribing`, so an unbounded loop pinned the HUD with no way out.
    /// Once spent, remaining chunks take the rules pass, same as any other
    /// model failure. 30 s matches the ASR deadline; every stage is bounded.
    static let aiBudget: TimeInterval = 30

    /// The AI tier, paragraph-aware (audit 2026-08-25): the sentence-boundary
    /// split ate newlines and chunks rejoined with a single space — but
    /// newlines are load-bearing (BasicCleanup preserves them, CleanupGate
    /// rejects invented ones). Lines clean independently, separators survive.
    @available(macOS 26.0, *)
    private static func aiOutcome(_ text: String) async -> Outcome {
        let deadline = Date().addingTimeInterval(aiBudget)
        // Latency step 1 (2026-08-27): merge short adjacent sentences into
        // one model call. Default ON since the A/B bench (docs/bench/
        // p1_run2_off.txt vs p1_run2_on.txt): e2e p95 3.54 s → 2.56 s, cleanup
        // p95 −39%, model calls 160 → 120, cleaned text byte-identical on
        // every merged clip, every gate rejection on the same unmerged clip
        // in both arms. The remote flag `cleanup_coalesce` is the kill
        // switch; local override via
        //   defaults write com.local.reed reed.flagOverride.cleanup_coalesce -bool NO
        let coalesce = await MainActor.run {
            FeatureFlags.shared.isEnabled(coalesceFlag, default: true)
        }
        // Item 2 of the cleanup-quality track (2026-08-29): a pause-fragment
        // ("…still has.") is cleaned with the sentence after it. Kill switch:
        //   defaults write com.local.reed reed.flagOverride.cleanup_fragment_glue -bool NO
        let glue = await MainActor.run {
            FeatureFlags.shared.isEnabled(fragmentGlueFlag, default: true)
        }
        var reason: String?
        var lines: [String] = []
        var anyModelOutput = false
        for paragraph in text.components(separatedBy: "\n") {
            let line = paragraph.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                lines.append("")
                continue
            }
            let cleaned = await cleanLine(line, deadline: deadline, coalesce: coalesce, glue: glue)
            if reason == nil {
                reason = cleaned.reason
            } else {
                for suffix in ["+gate-reject", "+budget"]
                where cleaned.reason?.contains(suffix) == true && reason?.contains(suffix) != true {
                    reason? += suffix
                }
            }
            anyModelOutput = anyModelOutput || cleaned.usedModel
            lines.append(cleaned.text)
        }
        // Honest label (review 2026-08-26): when EVERY chunk fell back to
        // rules, reporting "on-device AI" told the user the model cleaned a
        // dictation it never touched — the timings line and the HUD pill
        // must name what actually produced the text.
        return Outcome(text: lines.joined(separator: "\n"),
                       path: anyModelOutput ? .ai : .basic, reason: reason ?? "always")
    }

    /// One cleaned line: the text, the routing reason, and whether at least
    /// one chunk kept the model's output rather than the rules fallback.
    private struct LineOutcome {
        let text: String
        let reason: String?
        let usedModel: Bool
    }

    /// Remote flag key for sentence coalescing (see aiOutcome).
    static let coalesceFlag = "cleanup_coalesce"
    /// Cleanup-quality item 2: glue pause-fragments to the next sentence.
    static let fragmentGlueFlag = "cleanup_fragment_glue"

    /// One line's per-sentence model loop (the pre-paragraph shape, plus the
    /// aggregate deadline).
    @available(macOS 26.0, *)
    private static func cleanLine(_ text: String, deadline: Date, coalesce: Bool, glue: Bool) async -> LineOutcome {
        var pieces: [String] = []
        var reason: String?
        var usedModel = false
        for piece in SentenceChunker.chunks(text, coalesce: coalesce, glueFragments: glue) {
            // A resplit fragment opens mid-sentence; the model does better
            // on a sentence, so it gets a capital and the seam is restored
            // on rejoin (finding 5, 2026-08-29).
            let chunk = piece.continuesPrevious ? Self.capitalizingFirst(piece.text) : piece.text
            defer {
                if piece.continuesPrevious, pieces.count >= 2 {
                    let joined = Self.joinFragment(previous: pieces[pieces.count - 2], next: pieces[pieces.count - 1],
                                                   restoreLowercase: piece.text.first?.isLowercase == true)
                    pieces.removeLast(2); pieces.append(joined)
                }
            }
            let structural = structuralReason(chunk)
            reason = reason ?? structural
            Self.observer?.chunkStarted(input: chunk, repairHint: structural)
            // Budget spent — rules carry the rest of the dictation.
            guard Date() < deadline else {
                pieces.append(BasicCleanup.close(BasicCleanup.clean(chunk)))
                if reason?.contains("+budget") != true {
                    reason = (reason ?? "always") + "+budget"
                }
                Self.observer?.chunkDelivered(pieces[pieces.count - 1], outcome: .budgetSkipped, reason: nil)
                continue
            }
            // Acceptance is three nets: non-empty, the recall backstop, and
            // the word-alignment gate (CleanupGate) enforcing the prompts'
            // deletion-only contract (`modelAttempt`). A rejection falls
            // back to rules, so it is never worse than having no model.
            var attempt = await modelAttempt(chunk: chunk, repair: structural != nil)
            // The repair prompt over-edits now and then (adds a word, rewrites
            // a clause); when the gate refuses it, the generic prompt gets
            // the chunk before rules do — one more call, only on rejection.
            if attempt.accepted == nil, structural != nil,
               Date().addingTimeInterval(CleanupStats.floorDeadline) < deadline {
                attempt = await modelAttempt(chunk: chunk, repair: false)
            }
            let gateRejected = attempt.gate
            if let cleaned = attempt.accepted {
                // Repair path post-check: fillers are CONFIRMED present,
                // so one the model left behind (4 of 12, 2026-08-14)
                // gets the rules pass over the model's output. The
                // default path skips this — the v4 prompt deliberately
                // keeps a *mentioned* "um", and rules would delete it.
                // A restart the model left as spoken is collapsed under the
                // same licence the gate would have accepted it under — ONCE:
                // the rules pass collapses too (review 2026-09-06, P2).
                let kept = structural != nil && BasicCleanup.hasStrippableFiller(cleaned)
                    ? BasicCleanup.clean(cleaned) : RestartLicence.collapse(cleaned)
                pieces.append(BasicCleanup.polish(kept))
                usedModel = true
                Self.observer?.chunkDelivered(pieces[pieces.count - 1], outcome: .modelAccepted, reason: nil)
            } else {
                // This chunk's model call failed/was rejected — rules
                // carry it; the other chunks keep their model output.
                pieces.append(BasicCleanup.close(BasicCleanup.clean(chunk)))
                // Surface gate rejections in the usage log — "did the
                // gate block a good fix" must be readable, not guessed.
                // The verdict travels with the attempt (review 2026-09-04):
                // a failure is this call's, never a stale one from earlier.
                let failure = attempt.failure
                if let gateRejected {
                    if reason?.contains("+gate-reject") != true {
                        // Which rule, not just that one fired — content-free.
                        reason = (reason ?? "always") + "+gate-reject(\(gateRejected.rawValue))"
                        log.notice("cleanup gate rejected the model's output: \(gateRejected.rawValue) (repair hint: \(structural ?? "none"))")
                    }
                } else if let failure, reason?.contains("+model-") != true {
                    // The model itself failed — timeout, error, empty — and
                    // the timings line says which (field 2026-08-29: three
                    // 8 s stalls read as a bare "basic 8.2s").
                    reason = (reason ?? "always") + "+model-\(failure)"
                }
                let outcome: ReviewRecord.ChunkOutcome = gateRejected != nil ? .rulesAfterRejection : (failure != nil ? .modelFailed : .rulesOnly)
                Self.observer?.chunkDelivered(pieces[pieces.count - 1], outcome: outcome, reason: failure)
            }
        }
        return LineOutcome(text: pieces.joined(separator: " "), reason: reason, usedModel: usedModel)
    }

    static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    /// Rejoin a resplit fragment to the piece before it: the previous
    /// piece loses the sentence mark the model closed it with, and the
    /// opener goes back to lowercase when it was lowercase in the input —
    /// we capitalized it for the model; a name the input already
    /// capitalized ("GitHub") and "I" keep their case.
    static func joinFragment(previous: String, next: String, restoreLowercase: Bool) -> String {
        var head = previous
        while let last = head.last, ".!?…".contains(last) { head.removeLast() }
        var tail = next
        if restoreLowercase, let first = tail.first, first.isUppercase {
            let word = String(tail.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
            let keeps = word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")
            if !keeps { tail = String(first).lowercased() + tail.dropFirst() }
        }
        return head + " " + tail
    }

    /// Does this transcript show signals the AI tier is actually good at
    /// (disfluencies, self-corrections, missing punctuation)? Conservative on
    /// purpose: any signal → use AI. Only provably-clean text takes the fast
    /// path, where Basic is byte-equivalent in practice.
    static func needsAI(_ text: String) -> Bool { needsAIReason(text) != nil }

    /// Structural disfluency: evidence the SPEECH was broken, not just that a
    /// filler word appears. Evaluated on the raw transcript, and a hit routes
    /// to the repair prompt. Tuned on the 38-dictation capture corpus
    /// (2026-08-14): every genuinely garbled row fires at least one of these;
    /// the apostrophe guards kill the two contraction false-positives
    /// ("it's supposed" is not an s-stutter).
    static func structuralReason(_ text: String) -> String? {
        // "uh uh" / "um, um" — a doubled filler marks a real struggle.
        if text.range(of: #"(?i)\b(?:um+|uh+)\b[,\s]+(?:um+|uh+)\b"#,
                      options: .regularExpression) != nil { return "doubled-filler" }
        // "the the", "it it", "re re(work)" — adjacent doubled word.
        if text.range(of: #"(?i)(?<!['’])\b(\w+)[,\s]+\1\b(?!['’])"#,
                      options: .regularExpression) != nil { return "doubled-word" }
        // "and then uh and then" — doubled word pair, fillers allowed between.
        if text.range(of: #"(?i)\b(\w+\s+\w+)[,\s]+(?:(?:um+|uh+)[,\s]+)?\1\b"#,
                      options: .regularExpression) != nil { return "bigram-restart" }
        // "s significantly", "c cloud" — a stranded first letter.
        if text.range(of: #"(?i)(?<!['’])\b(\w)\s+\1\w{2,}"#,
                      options: .regularExpression) != nil { return "stutter" }
        // "the open the show me the…" — determiner-dense word-overlap restart.
        if text.range(of: #"(?i)\bthe\s+\w+\s+the\s+(?:\w+\s+){1,2}the\b"#,
                      options: .regularExpression) != nil { return "det-restart" }
        // Two or more fillers MID-phrase (an utterance- or sentence-initial
        // "Um," is normal cadence; mid-phrase ones track broken speech).
        if midPhraseFillerCount(text) >= 2 { return "filler-dense" }
        // Repair-prompt trigger round (2026-08-29): the field stumbles the
        // repair prompt fixes and the generic one leaves alone.
        if let restart = StumbleDetector.restart(text) { return restart }
        return nil
    }

    /// Counts fillers that are not at the start of the utterance or of a
    /// sentence — the positions where they signal disfluency rather than
    /// cadence.
    private static func midPhraseFillerCount(_ text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b(?:um+|uh+)\b"#) else { return 0 }
        let ns = text as NSString
        var count = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let before = ns.substring(to: match.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = before.last, !".!?".contains(last) { count += 1 }
        }
        return count
    }

    /// The first disfluency signal found, or nil when the text is provably
    /// clean. The reason string reaches the usage log, so trigger rates can
    /// be read off real use instead of reconstructed after the fact.
    static func needsAIReason(_ text: String) -> String? {
        // Fillers / verbal tics anywhere (incl. comma-bounded forms).
        if text.range(of: #"(?i)\b(um+|uh+|uhm|erm|you know|i mean)\b"#,
                      options: .regularExpression) != nil { return "filler" }
        if text.range(of: #"(?i),\s*like\s*,"#, options: .regularExpression) != nil { return "aside" }
        // Self-correction cues ("wait, no", "no wait", "I mean", "scratch that").
        if text.range(of: #"(?i)\b(wait,?\s+no|no,?\s+wait|scratch that|actually,?\s+no)\b"#,
                      options: .regularExpression) != nil { return "self-correction" }
        // Unpunctuated tail — ASR that didn't close the sentence needs the model.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, !BasicCleanup.closers.contains(last) { return "open-tail" }
        // Long run-on with almost no punctuation relative to length.
        let words = trimmed.split { $0 == " " }.count
        let marks = trimmed.filter { ".,!?;:".contains($0) }.count
        if words >= 12, marks <= 1 { return "run-on" }
        return nil
    }

    /// Rejects on-device output that has drifted too far from the dictation —
    /// the small model's occasional "hallucinate something unrelated" failure
    /// (the fabricated-breakfast bug). `minRecall` is the fraction of the input's
    /// content words that must survive in the output. `maxGrowth` optionally caps how much longer the
    /// output may be than the input. Inputs under three words are always accepted
    /// — too little signal to judge — and a rejection just falls back to Basic.
    static func looksFaithful(input: String, output: String,
                              minRecall: Double, maxGrowth: Double? = nil) -> Bool {
        let inWords = words(input)
        guard inWords.count >= 3 else { return true }
        let outWords = words(output)
        if let maxGrowth, Double(outWords.count) > Double(inWords.count) * maxGrowth {
            return false
        }
        let outSet = Set(outWords)
        let kept = inWords.reduce(0) { outSet.contains($1) ? $0 + 1 : $0 }
        return Double(kept) / Double(inWords.count) >= minRecall
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
