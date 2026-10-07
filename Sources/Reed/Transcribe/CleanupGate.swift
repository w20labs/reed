import Foundation

/// Word-alignment gate on the AI cleanup output (2026-08-19). The prompts
/// promise deletion-only editing; this enforces it mechanically, so the
/// prompts can be braver than a promise alone would allow. Every rule below
/// is anchored to an observed failure:
///
/// - "pursuance" → "pursuit" and an invented clause (battery, 2026-08-14):
///   any output word absent from the input rejects.
/// - "I can't understand…" hallucinated from "is can I trying" (bench,
///   2026-08-19): the added word ALSO flips negation — counted separately
///   because a lost "not" is the worst possible edit.
/// - "It was really really bad." → "really bad" (bench): a deleted repeat of
///   a content word is emphasis, not an accident — only function-word
///   repeats ("the the") may collapse.
/// - "Move it to the left. Sorry, right." → kept the WRONG side, and
///   "Do not do it." → "Do it." (both benches): the abandoned-option
///   deletion always reached the END of the text. A structural deletion
///   touching the final word is truncation or wrong-option-kept — rejected.
///
/// Licenses added from the gate bench (docs/bench/gate_verdicts.txt,
/// 2026-08-29 — 7 of 13 rejections were correct fixes):
/// - Phrase restart: "tell them tell the team", "I want to I want to go" —
///   a deleted span whose first word is re-spoken right after it, or that
///   repeats a phrase said just before it, is an abandoned start.
/// - Modals are checked by presence, negations by count: "we should
///   probably we should ship" lost one of two "should"s to a restart.
/// - A leading discourse opener ("so", "but", "okay") may go; a leading
///   article may not ("the counter…" is a resplit fragment, not an aside).
/// - Comma-delimited parentheticals (", you know,", ", like,") are fillers.
///
/// Round 2 (2026-08-29, the user's two-minute reads, docs/bench/gate_round2_*):
/// - A restart may be up to 8 words ("can someone and Dana and Mar — can
///   someone add…"), and a short (≤ 3 words) restart may open with a
///   function word ("on her — on the office").
/// - An adjacent repeat of a negation counts once ("hasn't hasn't").
/// - Several stumbles fixed in one chunk are fine when every deleted span
///   is licensed on its own (up to three); a single unlicensed span still
///   rejects.
///
/// On rejection the caller falls back to the rules pass — same path as a
/// model error, so a rejection is never worse than no model at all.
enum CleanupGate {
    /// Why an output was refused — content-free, so it can be logged and
    /// counted from real use (cleanup-quality track, 2026-08-29: two of three
    /// rejections in one field session were the gate blocking correct fixes,
    /// and nothing recorded which rule fired).
    enum Rejection: String {
        case protectedToken = "protected-token"
        case addedWord = "added-word"
        case negationChanged = "negation"
        case newlineAdded = "newline"
        case emphasisRepeat = "emphasis-repeat"
        case truncation = "truncation"
        case unlicensedDeletion = "unlicensed-deletion"
        case multipleDeletions = "multiple-deletions"
    }

    /// Stumbles a chunk may lose at once, each licensed on its own.
    static let maxStructuralSpans = 3

    static func accepts(input: String, output: String, repairHint: Bool) -> Bool {
        rejection(input: input, output: output, repairHint: repairHint) == nil
    }

    /// The first failing check, or nil. The one implementation is
    /// `verdict`; this is its `rejection`, so the decision cannot drift
    /// from the structure (proven against a frozen copy of the pre-verdict
    /// gate over every recorded pair and thousands of generated variants).
    static func rejection(input: String, output: String, repairHint: Bool) -> Rejection? {
        verdict(input: input, output: output, repairHint: repairHint).rejection
    }

    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "mm", "ah"]
    /// Repeats of these collapse silently ("the the"); a repeat of anything
    /// else is emphasis and must survive. The one list, shared with the
    /// restart licence.
    private static var functionWords: Set<String> { RestartLicence.functionWords }
    /// Repeated adjacent, these are stumbles, never emphasis.
    private static let auxiliaries: Set<String> = [
        "am", "are", "was", "were", "be", "been", "has", "have", "had", "do", "does", "did",
        "will", "would", "can", "could", "should", "shall", "may", "might", "must"
    ]
    /// Words that mark a spoken self-correction. Their presence licenses one
    /// structural deletion span even without the repair hint.
    private static let markers: Set<String> = [
        "sorry", "rather", "wait", "mean", "scratch", "actually", "no", "okay"
    ]
    /// Deleting one of these changes what the sentence obligates or denies.
    /// Bare "no" is excluded deliberately — it is usually the correction
    /// marker; inversion damage always shows up as a lost "not"/"n't".
    private static let negations: Set<String> = ["not", "never", "cannot"]
    /// Losing the only one changes what the sentence obligates; losing one
    /// of two to a restart does not.
    private static let modals: Set<String> = ["must", "should", "shall", "may"]
    /// Words a dictation may open with that carry no content ("so", "okay
    /// so", "but") — an article or pronoun at the start is content.
    private static let openers: Set<String> = ["so", "but", "and", "okay", "well", "oh", "yeah", "right"]
    /// Discourse fillers that are fillers only when spoken as an aside —
    /// comma-delimited in the transcript ("thinking, you know, maybe").
    private static let parentheticals: [[String]] = [
        ["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"], ["like"], ["basically"], ["right"]
    ]

    // swiftlint:disable cyclomatic_complexity
    /// The whole verdict. Every check runs and records what it found; the
    /// rejection is the first failure in the order the checks have always
    /// had: protected token, added word, negation, modal, newline, then
    /// the deleted spans in input order with, inside a span, emphasis
    /// before truncation before licence before the span cap.
    static func verdict(input: String, output: String, repairHint: Bool) -> GateVerdict {
        let inputTokens = tokens(of: input)
        let inRaw = inputTokens.map(\.text), outRaw = rawTokens(output)
        let inTok = inRaw.map(fold), outTok = outRaw.map(fold)
        let negations = GateVerdict.Negations(input: negationCount(inRaw), output: negationCount(outRaw))
        let inModals = modalSet(inTok), outModals = modalSet(outTok)
        let newlinesAdded = max(0, output.filter({ $0.isNewline }).count - input.filter({ $0.isNewline }).count)
        func make(_ rejection: Rejection?, deletions: [GateVerdict.Deletion], additions: [GateVerdict.Addition], protectedMissing: [String]) -> GateVerdict {
            GateVerdict(rejection: rejection, inputTokens: inputTokens, deletions: deletions, additions: additions, negations: negations,
                    modalsMissing: inModals.subtracting(outModals), modalsAdded: outModals.subtracting(inModals),
                    protectedMissing: protectedMissing, newlinesAdded: newlinesAdded)
        }
        // A tokenless input (empty, or punctuation only) has always been
        // accepted whatever the proposal; the map still names every proposal
        // token as an addition, so it reconstructs (review 2026-09-08, P3).
        guard !inTok.isEmpty else {
            let additions = outTok.enumerated().map { GateVerdict.Addition(outputToken: $0.offset, word: $0.element) }
            return make(nil, deletions: [], additions: additions, protectedMissing: [])
        }
        let asides = parentheticalIndices(input, tokenCount: inTok.count)

        // 0. Protected tokens (spec §6, 2026-08-19): anything the vocabulary
        // formatter could have built — a token containing '.', '/', '@', ':',
        // or both a digit and a letter ("I-485", "H-1B", "83(b)") — must
        // survive byte-identical. Word-level alignment can't catch the model
        // reformatting "I-485" into "I 485"; the tokens align too well.
        // Judged after the spans (below): a deletion is not a reformat.

        // 1. No additions: every output word was spoken. The DECISION is the
        // frequency test it has always been; the edit map's additions are the
        // proposal tokens the alignment below could not match, at the
        // occurrence consistent with the input's order.
        var counts: [String: Int] = [:]
        for token in inTok { counts[token, default: 0] += 1 }
        var wordAdded = false
        for token in outTok {
            if let remaining = counts[token], remaining > 0 { counts[token] = remaining - 1 } else { wordAdded = true }
        }
        let aligned = alignment(input: inTok, output: outTok)
        let additions = aligned.added.map { GateVerdict.Addition(outputToken: $0, word: outTok[$0]) }

        // 3. Every deleted span must be explainable — classified for every
        // span, whatever the earlier checks found.
        var deletions: [GateVerdict.Deletion] = []
        var structuralSpans = 0
        var spanRejection: Rejection?
        for rawSpan in aligned.deleted {
            // LCS ties resolve toward the earlier match, which can report
            // "them tell" for a speaker who said "tell them tell the team";
            // slide the CLASSIFICATION window left while the alignment is
            // equivalent. The map keeps the aligned span.
            var span = rawSpan
            while span.lowerBound > 0, inTok[span.lowerBound - 1] == inTok[span.upperBound - 1] {
                span = (span.lowerBound - 1)..<(span.upperBound - 1)
            }
            let characters = inputTokens[rawSpan.lowerBound].characters.lowerBound..<inputTokens[rawSpan.upperBound - 1].characters.upperBound
            func record(licence: GateVerdict.Licence?, fault: GateVerdict.Fault?) {
                deletions.append(.init(tokens: rawSpan, window: span, characters: characters, licence: licence, fault: fault))
            }
            // A leading discourse opener ("so", "but", "okay so") may go.
            if span.lowerBound == 0, span.allSatisfy({ openers.contains(inTok[$0]) || markers.contains(inTok[$0]) }) {
                record(licence: .opener, fault: nil); continue
            }
            // The one restart rule (RestartLicence): shared with the rules
            // pass and seam assembly, so a restart the model deletes and a
            // restart the app collapses itself are the same thing.
            // ...unless, at the end, it loses the correction's new option.
            if RestartLicence.isRestart(span, tokens: inTok), losesNewOptionAtEnd(rawSpan, input: inTok, output: outTok) { record(licence: nil, fault: .truncation); spanRejection = spanRejection ?? .truncation; continue }
            if RestartLicence.isRestart(span, tokens: inTok) { record(licence: .restart, fault: nil); continue }
            var isStructural = false
            var emphasis = false
            for i in span {
                let word = inTok[i]
                if fillers.contains(word) || asides.contains(i) { continue }
                // Stutter: a strict prefix of the next DIFFERENT token, with
                // any number of identical repeats between ("p p pretty",
                // "re re rework", "c cloud").
                var next = i + 1
                while next < inTok.count, inTok[next] == word { next += 1 }
                if next < inTok.count, inTok[next].hasPrefix(word), word.count < inTok[next].count { continue }
                // Adjacent repeat: silent collapse for function words only —
                // a repeated content word is emphasis, hard reject.
                let repeatsNeighbor = (i + 1 < inTok.count && inTok[i + 1] == word)
                    || (i > 0 && inTok[i - 1] == word)
                if repeatsNeighbor {
                    // Auxiliaries and negations can't be emphasis either:
                    // "hasn't hasn't been", "is is" (round 2).
                    // Nor can a doubled marker: "no, no, actually" is one cue.
                    if functionWords.contains(word) || auxiliaries.contains(word) || isCue(i, inTok)
                        || inRaw[i].hasSuffix("n't") { continue }
                    emphasis = true; break
                }
                // Near repeat: a duplicated function word within a few tokens
                // is a restart artifact, not content — "Is this sentence is
                // grammatically correct?" (field 2026-08-19: the gate was
                // rejecting the model's correct fix of exactly this).
                if functionWords.contains(word) {
                    let lo = max(0, i - 4), hi = min(inTok.count - 1, i + 4)
                    if (lo...hi).contains(where: { $0 != i && inTok[$0] == word }) { continue }
                }
                if isCue(i, inTok) { continue }
                isStructural = true
            }
            if emphasis { record(licence: nil, fault: .emphasisRepeat); spanRejection = spanRejection ?? .emphasisRepeat; continue }
            guard isStructural else { record(licence: .incidental, fault: nil); continue }
            structuralSpans += 1
            // A structural deletion that reaches the end of the input is
            // truncation or a wrong-option resolution.
            if span.contains(inTok.count - 1) { record(licence: nil, fault: .truncation); spanRejection = spanRejection ?? .truncation; continue }
            // Each span needs its own license: the repair hint or a marker
            // inside/adjacent to it. Up to `maxStructuralSpans` of them —
            // a chunk with four stumbles loses four spans (round 2).
            let licensed = repairHint || spanNearMarker(span, tokens: inTok)
            if !licensed { record(licence: nil, fault: .unlicensed); spanRejection = spanRejection ?? .unlicensedDeletion; continue }
            if structuralSpans > maxStructuralSpans { record(licence: nil, fault: .tooMany); spanRejection = spanRejection ?? .multipleDeletions; continue }
            record(licence: .structural, fault: nil)
        }
        let protectedMissing = unexcusedProtected(input: input, output: output, tokens: inputTokens, deletions: deletions)

        let rejection: Rejection?
        if !protectedMissing.isEmpty { rejection = .protectedToken }
        else if wordAdded { rejection = .addedWord }
        else if negations.input != negations.output || inModals != outModals { rejection = .negationChanged }
        else if newlinesAdded > 0 { rejection = .newlineAdded }
        else { rejection = spanRejection }
        return make(rejection, deletions: deletions, additions: additions, protectedMissing: protectedMissing)
    }
    // swiftlint:enable cyclomatic_complexity

    // MARK: - Pieces

    /// A marker is a correction cue only with something after it: a
    /// trailing "No." is content ("Do it. No.").
    private static func isCue(_ i: Int, _ tokens: [String]) -> Bool {
        markers.contains(tokens[i]) && i < tokens.count - 1
    }

    /// A restart deletion reaching the end may only lose words kept
    /// elsewhere: a window slid over an LCS tie always "re-speaks" its first
    /// word, and "seven pm. Sorry, five pm." → "seven pm." lost the new
    /// option (field 2026-10-06). Markers and fillers do not count.
    private static func losesNewOptionAtEnd(_ raw: Range<Int>, input: [String], output: [String]) -> Bool {
        guard raw.contains(input.count - 1) else { return false }
        let kept = Set(output)
        return raw.contains { !kept.contains(input[$0]) && !markers.contains(input[$0]) && !fillers.contains(input[$0]) }
    }

    private static func rawTokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }

    private static func fold(_ token: String) -> String {
        token.replacingOccurrences(of: "'", with: "")
    }

    private static func isNegation(_ token: String) -> Bool {
        negations.contains(fold(token)) || token.hasSuffix("n't")
    }

    /// An adjacent repeat of a negation is a stumble, not a second negation
    /// ("hasn't hasn't been" — round 2); it counts once, so collapsing it
    /// does not read as a lost "not".
    private static func negationCount(_ rawTokens: [String]) -> Int {
        var count = 0
        var previous: String?
        for token in rawTokens {
            if isNegation(token), token != previous { count += 1 }
            previous = token
        }
        return count
    }

    private static func modalSet(_ tokens: [String]) -> Set<String> {
        Set(tokens.filter { modals.contains($0) })
    }

    /// One whitespace word of the input, with its token span and commas.
    private struct Word {
        let tokens: [String]
        let firstIndex: Int
        let leadingComma: Bool
        let trailingComma: Bool
    }

    /// Token indices of comma-delimited discourse asides (", you know,",
    /// ", like,") — fillers by position, not by word.
    private static func parentheticalIndices(_ text: String, tokenCount: Int) -> Set<Int> {
        var words: [Word] = []
        var index = 0
        var previousTrailingComma = true   // an aside may open the text
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let tokens = rawTokens(String(raw)).map(fold)
            let trailing = raw.last.map { ",;".contains($0) } ?? false
            words.append(Word(tokens: tokens, firstIndex: index, leadingComma: previousTrailingComma, trailingComma: trailing))
            index += tokens.count
            previousTrailingComma = trailing || (raw.last.map { ".!?".contains($0) } ?? false)
        }
        var result: Set<Int> = []
        for (i, word) in words.enumerated() where word.leadingComma {
            for phrase in parentheticals {
                let run = words[i..<min(i + phrase.count, words.count)]
                guard run.count == phrase.count, run.flatMap(\.tokens) == phrase,
                      run.last?.trailingComma == true else { continue }
                for offset in 0..<phrase.count { result.insert(word.firstIndex + offset) }
            }
        }
        return result.filter { $0 < tokenCount }
    }

    private static func spanNearMarker(_ span: Range<Int>, tokens: [String]) -> Bool {
        let lo = max(0, span.lowerBound - 1)
        let hi = min(tokens.count - 1, span.upperBound)
        return (lo...hi).contains { markers.contains(tokens[$0]) }
    }

    /// The one alignment (LCS, the traceback the gate has always used):
    /// contiguous input index ranges absent from the output, and the output
    /// indices matched to nothing. Deletions are disjoint; input minus the
    /// deletions equals output minus the additions.
    static func alignment(input: [String], output: [String]) -> (deleted: [Range<Int>], added: [Int]) {
        let rows = input.count, cols = output.count
        var lcs = Array(repeating: Array(repeating: 0, count: cols + 1), count: rows + 1)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for col in stride(from: cols - 1, through: 0, by: -1) {
                lcs[i][col] = input[i] == output[col]
                    ? lcs[i + 1][col + 1] + 1
                    : max(lcs[i + 1][col], lcs[i][col + 1])
            }
        }
        var spans: [Range<Int>] = []
        var added: [Int] = []
        var i = 0, col = 0
        var spanStart: Int?
        while i < rows {
            if col < cols, input[i] == output[col], lcs[i][col] == lcs[i + 1][col + 1] + 1 {
                if let s = spanStart { spans.append(s..<i); spanStart = nil }
                i += 1; col += 1
            } else if col < cols, lcs[i][col + 1] >= lcs[i + 1][col] {
                added.append(col)
                col += 1
            } else {
                if spanStart == nil { spanStart = i }
                i += 1
            }
        }
        if let s = spanStart { spans.append(s..<rows) }
        while col < cols { added.append(col); col += 1 }
        return (spans, added)
    }
}
