import Foundation

/// The built-in vocabulary correction pass (spec: IMPLEMENTATION_PROMPT,
/// approved 2026-08-19): two deterministic stages between ASR and the LLM —
/// the spoken-forms formatter, then literal term correction. No model calls,
/// no network, no fuzziness: the table ships invisible, so every substitution
/// must be exactly one a human reviewed.
///
/// This is the ONLY place in the pipeline allowed to substitute one word for
/// another. The LLM stage stays deletion-only, enforced by CleanupGate.

/// One token of the original text: the whitespace-delimited span, the
/// punctuation-stripped core, and the normalized form used for matching.
struct VocabToken {
    let norm: String
    let core: Range<String.Index>
    let full: Range<String.Index>
    /// Trailing clause punctuation after the core ("app." / "one,"): no
    /// multi-token match or formatter walk may continue PAST this token —
    /// "the app. Store the files" is not App Store, "Pick one. Am I wrong?"
    /// is not 1:00 AM (audit 2026-08-25).
    let sealed: Bool
}

struct Substitution {
    let range: Range<Int>        // offsets in the OUTPUT text
    let original: String
    let replacement: String
    let domain: VocabDomain
    let rule: String             // "always" | "gated"
}

struct FormattedSpan {
    let range: Range<Int>        // offsets in the OUTPUT text
    let pattern: String
}

struct CorrectionResult {
    let text: String
    let substitutions: [Substitution]
    let formattedSpans: [FormattedSpan]
    let activeDomains: Set<VocabDomain>
}

enum CorrectionPass {
    /// A pending replacement of tokens `first...last` (core-to-core).
    struct Edit {
        let first: Int
        let last: Int
        let replacement: String
        let pattern: String?          // formatter pattern, nil for vocab
        let domain: VocabDomain?
        let rule: String?
    }

    static func apply(_ text: String, active: Set<VocabDomain>) -> CorrectionResult {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else {
            return CorrectionResult(text: text, substitutions: [], formattedSpans: [],
                                    activeDomains: active)
        }
        let legalActive = active.contains(.estate) || active.contains(.immigration)
        // The formatter's walks roam token runs freely, so they must never
        // SEE across a sealed token ("I have five. Dollars are scarce." is
        // not $5). Each clause is recognized independently; the resulting
        // edits shift back to whole-text indices.
        var edits: [CorrectionPass.Edit] = []
        var lo = 0
        for hi in tokens.indices where tokens[hi].sealed || hi == tokens.count - 1 {
            edits += SpokenFormatter.claims(tokens: Array(tokens[lo...hi]), text: text,
                                            legalActive: legalActive)
                .map { Edit(first: $0.first + lo, last: $0.last + lo,
                            replacement: $0.replacement, pattern: $0.pattern,
                            domain: $0.domain, rule: $0.rule) }
            lo = hi + 1
        }
        let claimed = Set(edits.flatMap { Array($0.first...$0.last) })
        edits += TermMatcher.substitutions(tokens: tokens, text: text,
                                           active: active, claimed: claimed)
        // Inverse text normalization last (2026-08-29): cardinals, ordinals
        // in dates, clock times — over tokens neither a formatter span nor a
        // vocabulary entry claimed, segment by segment like the formatter.
        let taken = Set(edits.flatMap { Array($0.first...$0.last) })
        lo = 0
        for hi in tokens.indices where tokens[hi].sealed || hi == tokens.count - 1 {
            let local = Set(taken.filter { (lo...hi).contains($0) }.map { $0 - lo })
            edits += SpokenFormatter.numberClaims(tokens: Array(tokens[lo...hi]), claimed: local)
                .map { Edit(first: $0.first + lo, last: $0.last + lo, replacement: $0.replacement,
                            pattern: $0.pattern, domain: $0.domain, rule: $0.rule) }
            lo = hi + 1
        }
        edits.sort { $0.first < $1.first }

        var out = ""
        var subs: [Substitution] = []
        var spans: [FormattedSpan] = []
        var cursor = text.startIndex
        for edit in edits {
            let start = tokens[edit.first].core.lowerBound
            let end = tokens[edit.last].core.upperBound
            // Recognizers must not emit overlapping claims, but a String
            // range with cursor past start is a fatal trap, not a bad edit —
            // so an overlap loses the later edit rather than the dictation.
            guard start >= cursor else { continue }
            out += text[cursor..<start]
            let outStart = out.count
            out += edit.replacement
            let range = outStart..<out.count
            if let pattern = edit.pattern {
                spans.append(FormattedSpan(range: range, pattern: pattern))
            } else if let domain = edit.domain, let rule = edit.rule {
                subs.append(Substitution(range: range, original: String(text[start..<end]),
                                         replacement: edit.replacement,
                                         domain: domain, rule: rule))
            }
            cursor = end
        }
        out += text[cursor...]
        return CorrectionResult(text: out, substitutions: subs,
                                formattedSpans: spans, activeDomains: active)
    }

    /// Whitespace-delimited tokens; the core strips edge punctuation (keeps
    /// internal apostrophes for entries like "what's app").
    static func tokenize(_ text: String) -> [VocabToken] {
        var tokens: [VocabToken] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            while idx < text.endIndex, text[idx].isWhitespace { idx = text.index(after: idx) }
            guard idx < text.endIndex else { break }
            let start = idx
            while idx < text.endIndex, !text[idx].isWhitespace { idx = text.index(after: idx) }
            let full = start..<idx
            var coreStart = full.lowerBound
            var coreEnd = full.upperBound
            while coreStart < coreEnd, !isCoreChar(text[coreStart]) {
                coreStart = text.index(after: coreStart)
            }
            while coreEnd > coreStart, !isCoreChar(text[text.index(before: coreEnd)]) {
                coreEnd = text.index(before: coreEnd)
            }
            let core = coreStart..<coreEnd
            let sealed = text[coreEnd..<full.upperBound].contains(where: sealingChars.contains)
            tokens.append(VocabToken(norm: text[core].lowercased(), core: core, full: full,
                                     sealed: sealed))
        }
        return tokens
    }

    private static func isCoreChar(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "'" || char == "’"
    }

    /// Punctuation that seals a token (see `VocabToken.sealed`). Interior
    /// dots/colons ("9.30", "3:30", "example.com") are core-internal and
    /// never reach this check — only edge punctuation does.
    private static let sealingChars: Set<Character> = [".", "!", "?", "…", ";", ":", ","]
}
