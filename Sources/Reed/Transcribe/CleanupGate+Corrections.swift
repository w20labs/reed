import Foundation

/// Spoken corrections the gate judges by their shape (natural
/// self-correction, 2026-10-14). Each rule is narrow: it names the one
/// structure that licenses (or forbids) a deletion, and everything else is
/// judged as before.
extension CleanupGate {
    /// One span's self-correction verdict, or nil when none of these shapes
    /// applies: a marked correction resolved backwards keeps the abandoned
    /// option; a completed contrast or a lone linker is not a stumble; a
    /// whole deleted sentence is a revision re-said right after it, or kept.
    static func correctionVerdict(raw: Range<Int>, window: Range<Int>, input: String, tokens: [GateVerdict.Token],
                                  keys: [String]) -> CorrectionVerdict? {
        if keepsAbandonedOption(raw, tokens: keys) { return .init(licence: nil, fault: .truncation, rejection: .truncation) }
        if deletesOnlyTheCue(raw, keys: keys) { return .init(licence: nil, fault: .unlicensed, rejection: .unlicensedDeletion) }
        if losesContrast(window, tokens: keys) || isLoneLinker(window, tokens: keys) {
            return .init(licence: nil, fault: .unlicensed, rejection: .unlicensedDeletion)
        }
        guard let revised = wholeSentenceVerdict(window, input: input, tokens: tokens, keys: keys) else { return nil }
        return revised ? .init(licence: .restart, fault: nil, rejection: nil)
            : .init(licence: nil, fault: .unlicensed, rejection: .unlicensedDeletion)
    }

    /// How a self-correction shape judged one deleted span.
    struct CorrectionVerdict {
        let licence: GateVerdict.Licence?
        let fault: GateVerdict.Fault?
        let rejection: Rejection?
    }

    /// Doubled words that are grammar, not a stumble: "We had had several
    /// discussions" is the past perfect of "have" (research fixture C10:
    /// the repair prompt collapsed it and the auxiliary rule let it go).
    static let grammaticalDoubles: Set<String> = ["had"]

    /// A marked correction resolved backwards: the deletion starts at the
    /// cue and takes the new option after it, keeping the abandoned one
    /// before it ("He has three, no wait, four kids." → "He has three
    /// kids.", validation V08 — accepted, because the span stopped short of
    /// the end, where `truncation` would have caught it). A deleted restart
    /// after the cue is a repair, not an option ("No wait, we should, we
    /// must go"), and a cue with nothing kept before it abandons nothing.
    static func keepsAbandonedOption(_ span: Range<Int>, tokens: [String]) -> Bool {
        guard span.lowerBound > 0, let cue = span.first(where: { isCuePart($0, tokens) }) else { return false }
        guard (span.lowerBound..<cue).allSatisfy({ fillers.contains(tokens[$0]) || isCuePart($0, tokens) }) else { return false }
        let after = (cue..<span.upperBound).filter { !isCuePart($0, tokens) && !fillers.contains(tokens[$0]) }
        guard let first = after.first, let last = after.last else { return false }
        return !RestartLicence.isRestart(first..<(last + 1), tokens: tokens)
    }

    /// Negations a marked correction deletes together with the option they
    /// deny: "The deadline is Friday, sorry, not Friday, Monday." → "The
    /// deadline is Monday." (research fixture M06 — the model's correct
    /// repair, refused as a lost "not"). Counted only when a cue is inside
    /// or beside the deleted span, the "not" and the word it negates are
    /// both deleted, and that word is the option abandoned earlier in the
    /// same span. A "not" that denies anything else still counts.
    static func correctionNegations(_ spans: [Range<Int>], input: String, tokens inputTokens: [GateVerdict.Token], keys tokens: [String]) -> Int {
        // A quoted example is content, never a spoken correction (review of
        // PR #29: deleting "Friday, sorry, not Friday, Monday" from inside
        // quotes passed).
        let quoted = quotedIndices(input: input, tokens: inputTokens)
        var count = 0
        // The cue must be spoken too: a quoted "sorry" beside an unquoted
        // span is content (second review of PR #29).
        for span in spans where quoted.isDisjoint(with: span)
            && (max(0, span.lowerBound - 1)...min(tokens.count - 1, span.upperBound)).contains(where: { isCue($0, tokens) && !quoted.contains($0) }) {
            for index in span where tokens[index] == "not" && span.contains(index + 1) {
                let option = tokens[index + 1]
                if (span.lowerBound..<index).contains(where: { tokens[$0] == option && !isCue($0, tokens) }) { count += 1 }
            }
        }
        return count
    }

    /// A cue word, or the other word of a two-word cue: the "I" of "I
    /// mean", the "that" of "scratch that".
    static func isCuePart(_ index: Int, _ tokens: [String]) -> Bool {
        if isCue(index, tokens) { return true }
        if tokens[index] == "i", index + 1 < tokens.count, tokens[index + 1] == "mean" { return isCue(index + 1, tokens) }
        if tokens[index] == "that", index > 0, tokens[index - 1] == "scratch" { return isCue(index - 1, tokens) }
        return false
    }

    /// Modals a restart replaces: "We should we must finish the audit" →
    /// "We must finish the audit" (validation V05). The modal is excused
    /// only inside a deleted span licensed as a restart, when the copy the
    /// speaker kept has a modal at the same position. Losing the only
    /// modal any other way is still a change of obligation.
    static func restartModals(_ deletions: [GateVerdict.Deletion], input: String, tokens inputTokens: [GateVerdict.Token],
                              keys tokens: [String], modals: Set<String>) -> Set<String> {
        let quoted = quotedIndices(input: input, tokens: inputTokens)
        var excused: Set<String> = []
        for deletion in deletions where deletion.licence == .restart && quoted.isDisjoint(with: deletion.tokens) {
            for index in deletion.tokens where modals.contains(tokens[index]) {
                let kept = deletion.tokens.upperBound + (index - deletion.tokens.lowerBound)
                // Replaced by any modal verb: "should" → "could" too (eleventh
                // review of PR #29: only a protected modal could replace one).
                if kept < tokens.count, modals.contains(tokens[kept]) || modalVerbs.contains(tokens[kept]) { excused.insert(tokens[index]) }
            }
        }
        return excused
    }

    /// A deleted span that is one or more whole sentences, with no
    /// correction cue in or beside it: true when the sentence right after it
    /// re-says it with a change ("We were going to go. We are going to go.",
    /// research U01), false when it does not — a completed contrast ("…go
    /// yesterday. …go tomorrow.", C01) or an elaboration ("We must test
    /// this. We must test this before release.", C03): the repair hint used
    /// to license any such deletion, and the prompt's new revision rule made
    /// the model take them. nil when the span is not whole sentences, or a
    /// cue judges it (the marker rules apply as before).
    ///
    /// A revision loses at most two words the next sentence does not have,
    /// at most one of them a content word, and the next sentence adds at
    /// most one word of its own.
    static func wholeSentenceVerdict(_ span: Range<Int>, input: String, tokens: [GateVerdict.Token], keys: [String]) -> Bool? {
        let content = span.filter { !fillers.contains(keys[$0]) }
        guard content.count >= 2 else { return nil }
        let startsSentence = span.lowerBound == 0 || endsSentence(span.lowerBound - 1, input: input, tokens: tokens)
        guard startsSentence, endsSentence(span.upperBound - 1, input: input, tokens: tokens), span.upperBound < keys.count else { return nil }
        // Quoted text is content: its sentences are never licensed away, and a
        // quoted cue beside the span is no cue (second review of PR #29: the
        // quoted case used to return nil, which skipped this refusal).
        let quoted = quotedIndices(input: input, tokens: tokens)
        if !quoted.isDisjoint(with: span) { return false }
        let near = max(0, span.lowerBound - 1)...min(keys.count - 1, span.upperBound)
        guard !near.contains(where: { isCuePart($0, keys) && !quoted.contains($0) }) else { return nil }
        var end = span.upperBound
        while end < keys.count - 1, !endsSentence(end, input: input, tokens: tokens) { end += 1 }
        // A chain of versions ("We were… We are… We will…") is checked step
        // by step, each deleted sentence revised by the one after it, the
        // last by the kept sentence — never as one combined sentence (third
        // review of PR #29).
        let chain = sentences(in: span, input: input, tokens: tokens).map { range in range.filter { !fillers.contains(keys[$0]) }.map { keys[$0] } }
            + [keys[span.upperBound...end].filter { !fillers.contains($0) }]
        return zip(chain, chain.dropFirst()).allSatisfy { isRevisionStep(from: $0, to: $1) }
    }

    /// One step of a revision: the later sentence re-says the earlier with a
    /// change — the earlier loses at most one content word (and at most
    /// three words in all), the later adds at most one word. A contrast or an
    /// elaboration adds more and is not a step.
    static func isRevisionStep(from earlier: [String], to later: [String]) -> Bool {
        // Judged on the versions as cleanup may repair them ("will will",
        // "l leave"), so a stumble inside one is not counted as a change.
        let earlier = repaired(earlier).map(identity), later = repaired(later).map(identity)
        let removed = subtracting(earlier, later), added = subtracting(later, earlier)
        let removedContent = removed.filter { !RestartLicence.functionWords.contains($0) && !auxiliaries.contains($0) }
        return removed.count <= 3 && removedContent.count <= 1 && added.count <= 1
    }

    /// The sentences inside `span`, as token ranges.
    static func sentences(in span: Range<Int>, input: String, tokens: [GateVerdict.Token]) -> [Range<Int>] {
        var out: [Range<Int>] = [], start = span.lowerBound
        for index in span where endsSentence(index, input: input, tokens: tokens) {
            out.append(start..<(index + 1)); start = index + 1
        }
        if start < span.upperBound { out.append(start..<span.upperBound) }
        return out
    }

    /// Whether the token at `index` ends a sentence: a mark follows it
    /// before the next word, or nothing follows it at all.
    static func endsSentence(_ index: Int, input: String, tokens: [GateVerdict.Token]) -> Bool {
        var position = tokens[index].characters.upperBound
        while position < input.endIndex {
            let character = input[position]
            if ".!?…".contains(character) { return true }
            if character.isLetter || character.isNumber { return false }
            position = input.index(after: position)
        }
        return true
    }

    /// `left` minus `right`, counting repeats.
    private static func subtracting(_ left: [String], _ right: [String]) -> [String] {
        var remaining = Dictionary(right.map { ($0, 1) }, uniquingKeysWith: +)
        return left.filter { word in
            guard let count = remaining[word], count > 0 else { return true }
            remaining[word] = count - 1
            return false
        }
    }

    /// Words that complete a contrast between two clauses.
    static let contrastWords: Set<String> = ["but", "yet", "although", "though", "whereas", "however"]

    /// A deleted span with a contrast word inside it, after something it
    /// contrasts with: "We were going to go, but we are going to stay." →
    /// "We were going to stay." (research C02 — the restart licence matched
    /// "going to go, but we are" as an abandoned "going to"). A span that
    /// opens with the word is a restarted conjunction ("but we, but we
    /// should"), judged as before.
    static func losesContrast(_ span: Range<Int>, tokens: [String]) -> Bool {
        span.dropFirst().contains { contrastWords.contains(tokens[$0]) && !isCuePart($0, tokens) }
    }

    /// A lone clause linker deleted where it is not a repeat: "I'll call you
    /// at noon, and I'll call him at one." → "…at noon. I'll call him…"
    /// (validation V11, under the repair hint). A repeated one ("and uh and
    /// then") is a near repeat, judged before this.
    static func isLoneLinker(_ span: Range<Int>, tokens: [String]) -> Bool {
        guard span.count == 1, let index = span.first, ["and", "or", "but", "yet"].contains(tokens[index]) else { return false }
        let near = max(0, index - 4)...min(tokens.count - 1, index + 4)
        return !near.contains { $0 != index && tokens[$0] == tokens[index] } && !isCuePart(index, tokens)
    }

    /// Modal verbs: two side by side are never English.
    static let modalVerbs: Set<String> = ["can", "cannot", "could", "should", "must", "will", "would", "may", "might", "shall"]

    /// A proposal that leaves two modals side by side the input did not
    /// have: "We should we must finish the audit" → "We should must finish
    /// the audit" (validation V05 — the model dropped only the re-spoken
    /// subject; a doubled "we" may always go, so nothing else caught it).
    static func joinsModals(input: [String], output: [String]) -> Bool {
        func pairs(_ words: [String]) -> Set<String> {
            Set(zip(words, words.dropFirst()).filter { modalVerbs.contains($0) && modalVerbs.contains($1) }.map { "\($0) \($1)" })
        }
        return !pairs(output).subtracting(pairs(input)).isEmpty
    }

    /// Modals are checked by presence: every modal missing from the output
    /// must be one a restart replaced, and none may be new. A replaced modal
    /// can still be spoken elsewhere ("We should we must finish today, and
    /// we should check the logs." — review of PR #29: subtracting the
    /// excused modal from the whole input refused that).
    static func modalsKept(input: Set<String>, output: Set<String>, excused: Set<String>) -> Bool {
        input.subtracting(output).isSubset(of: excused) && output.isSubset(of: input)
    }

    /// Token indices inside a double quotation ("…" or “…”). Quoted words are
    /// content — an example, a phrase being discussed — so they never
    /// license a correction. Single quotes are left out: they double as
    /// apostrophes.
    static func quotedIndices(input: String, tokens: [GateVerdict.Token]) -> Set<Int> {
        var ranges: [Range<String.Index>] = []
        var open: String.Index?
        for index in input.indices {
            switch input[index] {
            case "\"" where open == nil, "“": open = index
            case "\"", "”": if let start = open { ranges.append(start..<index); open = nil }
            default: break
            }
        }
        if let start = open { ranges.append(start..<input.endIndex) }
        return Set(tokens.indices.filter { token in ranges.contains { $0.contains(tokens[token].characters.lowerBound) } })
    }

    /// A subject restarted with a different modal keeps the LATER one: "We
    /// should we could try the other vendor." → "We should try…" lost the
    /// speaker's final "could" and passed, since presence protects only
    /// must/should/shall/may (eleventh review of PR #29). Protecting every
    /// modal by presence would refuse correct repairs of abandoned starts
    /// ("can you send the — do we have the report"); this protects exactly
    /// the restart's final modal, of any modal verb ("won't" and the other
    /// negated forms are already held by the negation count).
    static func dropsLaterModal(input: [String], output: [String]) -> Bool {
        let subjects: Set<String> = ["i", "we", "you", "he", "she", "they", "it"]
        let verbs = modalVerbs
        let kept = Dictionary(output.map { ($0, 1) }, uniquingKeysWith: +), spoken = Dictionary(input.map { ($0, 1) }, uniquingKeysWith: +)
        for index in input.indices where index + 3 < input.count && subjects.contains(input[index]) && verbs.contains(input[index + 1]) {
            for later in (index + 2)...min(input.count - 2, index + 3) where input[later] == input[index] {
                let final = input[later + 1]
                guard verbs.contains(final), final != input[index + 1] else { continue }
                if kept[final, default: 0] < spoken[final, default: 0] { return true }
            }
        }
        return false
    }

    /// A deletion of only a correction cue between kept words: "Our team
    /// has five, I mean, six open roles." → "…five six open roles." leaves
    /// both options as one false instruction (fallback review of PR #29). A
    /// correct proposal deletes the abandoned option with the cue. A sentence
    /// or paragraph break before the cue changes nothing: "…five. I mean,
    /// six open roles." → "…five. Six open roles." and a chunk that opens on
    /// the cue are the same unresolved correction (thirteenth review).
    static func deletesOnlyTheCue(_ raw: Range<Int>, keys: [String]) -> Bool {
        guard raw.upperBound < keys.count else { return false }
        return raw.allSatisfy { isCuePart($0, keys) || fillers.contains(keys[$0]) } && raw.contains { isCuePart($0, keys) }
    }
}
