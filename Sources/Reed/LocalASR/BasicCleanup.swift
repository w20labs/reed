import Foundation

// Split from LocalCleanup.swift (file_length, review 2026-08-26) — the
// rules tier grew past the 400-line strict-lint cap once the AI tier
// gained its budget/resplit machinery. Same module, no API change.
/// Conservative rules cleanup: removes clear filler words, fixes spacing and
/// sentence capitalization. It only ever *deletes* known fillers or adjusts
/// casing/whitespace — it never rewrites words, so meaning is preserved.
enum BasicCleanup {
    /// Bare fillers stripped anywhere. "you know" and "i mean" are NOT here —
    /// as bare phrases they are routinely content ("Do you know the answer?"),
    /// so they're only removed in the comma-bounded aside form below; the bare
    /// forms are left for the AI tier's judgement.
    private static let fillers = ["umm", "um", "uhh", "uhm", "uh", "erm"]

    /// A filler flush against a quote mark is being *mentioned*, not spoken
    /// ("as soon as I say \"um\"…") — the bare-word pass must never strip it.
    private static let quoteGuardBefore = #"(?<!["'“”‘’«»])"#
    private static let quoteGuardAfter = #"(?!["'“”‘’«»])"#

    /// True when the text still contains a bare, unquoted filler — i.e. one
    /// `clean` would strip. Used as the post-check on the AI tier's output.
    static func hasStrippableFiller(_ text: String) -> Bool {
        text.range(of: "(?i)\(quoteGuardBefore)\\b(?:umm?|uhh?|uhm|erm)\\b\(quoteGuardAfter)",
                   options: .regularExpression) != nil
    }

    static func clean(_ text: String) -> String {
        var s = text
        // Comma-bounded fillers first — ", uh," / ", like," / ", I mean," —
        // removing the whole aside avoids the comma debris the per-word pass
        // leaves ("we should, grab"). "like"/"I mean" are ONLY stripped in this
        // comma-bounded form: as bare words they're real content ("I like it").
        s = s.replacingOccurrences(
            of: "(?i),\\s*(?:umm?|uhh?|uhm|erm|like|i mean|you know)\\s*,",
            with: "", options: .regularExpression)
        for filler in fillers {
            s = s.replacingOccurrences(
                of: "(?i)\(quoteGuardBefore)\\b\(filler)\\b\(quoteGuardAfter),?\\s?",
                with: "", options: .regularExpression)
        }
        // A restart the speaker made ("tell me tell me what you think") is
        // a first-class edit here too (decision 2, 2026-09-04): the same
        // licence the gate applies to the model's deletions, so the rules
        // path is never worse than the model path on a plain restart.
        s = RestartLicence.collapse(s)
        // Tidy artifacts left by removals, then spacing/punctuation.
        s = s.replacingOccurrences(of: "\\s*,\\s*,", with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[,\\s]+", with: "", options: .regularExpression)
        // Collapse runs of spaces/tabs only — never across newlines, so
        // paragraph breaks in multi-line dictations survive cleanup.
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]+([,.!?;:])", with: "$1", options: .regularExpression)
        s = capitalizeSentences(s)
        // "i" the pronoun only — never the "i" inside a formatter-built token
        // ("i-485", "jane@i.co"): those are CleanupGate-protected and must
        // survive byte-identical (review 2026-08-26). "i'm"/"i'll" still
        // match; \b already excludes letter/digit neighbours.
        s = s.replacingOccurrences(of: "(?<![-@./:])\\bi\\b(?![-@./:])",
                                   with: "I", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Terminal punctuation that counts as a closed sentence. Shared with
    /// `LocalCleanup.needsAIReason`'s open-tail rule, so text `close` has
    /// closed can never re-trigger it.
    static let closers = ".!?…\"'”»)"

    /// Mechanics-only finish for model output: sentence capitalization plus
    /// a terminal close — never deletes or changes a word. The v4 prompt's
    /// "returning it unchanged is correct" line makes the model lazy about
    /// mechanics on clean-but-unpunctuated input (bench 2026-08-19: "ship
    /// the package to baker street" came back verbatim).
    static func polish(_ text: String) -> String {
        close(capitalizeSentences(text))
    }

    /// Close an open final sentence. ASR that stopped mid-breath leaves a
    /// trailing comma or nothing at all, and that used to route the whole
    /// dictation to the ~1.5 s model just to add one mark. A period is the
    /// dictation-safe default: a mis-closed question costs one character,
    /// and the model wasn't guaranteed to guess "?" either.
    ///
    /// NOT part of `clean` — that stays deletion/casing-only for parity with
    /// the backend's rules_clean; closing is the local AI tier's rules-first
    /// step (see `LocalCleanup.applyWithPath`).
    static func close(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        // A dangling separator is the open tail — replace it with the close.
        s = s.replacingOccurrences(of: "[,;:\\-–—\\s]+$", with: "", options: .regularExpression)
        guard let last = s.last, !closers.contains(last) else { return s }
        return s + "."
    }

    /// Uppercase the first letter of the text and of each sentence. A "."
    /// only ends a sentence when whitespace (or the end of text) follows —
    /// that one rule covers decimals ("9.30", "£15.50") and domains/emails
    /// ("example.com" was coming out "example.Com", probe 2026-08-19; same
    /// fix as the unmerged #233 branch). "phase 2. Next" still capitalizes:
    /// its "." is followed by a space.
    private static func capitalizeSentences(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        var capitalizeNext = true
        for (i, ch) in chars.enumerated() {
            if capitalizeNext, ch.isLetter {
                // A sentence OPENING on a formatter-built token
                // ("jane@example.com is my address", "x-1234 failed") must
                // not have it re-cased — CleanupGate just guaranteed those
                // survive the model byte-identical, and this pass ran two
                // lines later and broke the same guarantee (review
                // 2026-08-26). The sentence still counts as started.
                if Self.isInsideProtectedToken(chars, at: i) {
                    result.append(ch)
                } else {
                    result.append(contentsOf: ch.uppercased())
                }
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch == "!" || ch == "?" {
                    capitalizeNext = true
                } else if ch == "." {
                    let sentenceEnd = i + 1 >= chars.count || chars[i + 1].isWhitespace
                    if sentenceEnd { capitalizeNext = true }
                }
            }
        }
        return result
    }

    /// Whether the whitespace-delimited word containing index `i` is one
    /// CleanupGate protects (contains '.', '/', '@', ':' or mixes digits and
    /// letters — "jane@example.com", "x-1234"). Delegates the classification
    /// to `CleanupGate.protectedTokens` so the two can never disagree.
    private static func isInsideProtectedToken(_ chars: [Character], at i: Int) -> Bool {
        var start = i
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        var end = i
        while end < chars.count, !chars[end].isWhitespace { end += 1 }
        return !CleanupGate.protectedTokens(String(chars[start..<end])).isEmpty
    }
}
