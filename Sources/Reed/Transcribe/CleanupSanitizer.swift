import Foundation

/// Strips conversational packaging that a cleanup model sometimes adds despite a
/// "return only the cleaned text" instruction — a chatty preamble and/or
/// surrounding delimiters, e.g.:
///
///     Sure, I can help with that. Here's the cleaned text: «Hello world.»
///
/// Small on-device models are the worst offenders, so the on-device cleanup
/// path (`AICleanup`, the only caller) runs every model response through here
/// before it reaches the gate. The rules are deliberately high-precision: real dictated
/// speech routinely contains words like "okay", "sure", or "here's the plan:",
/// so a match requires an unambiguous packaging signal (a delimiter, or an
/// explicit clean/polish/format verb) — never a bare interjection.
enum CleanupSanitizer {
    static func strip(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Rule 1 — a preamble ending in a colon that is immediately followed by
        // an opening «/<</``` delimiter ("…: «", "…: <<"). Those delimiters
        // don't occur in normal cleaned prose, so this is a safe packaging tell.
        s = dropLeading(s, #"^[^\n]{0,200}?[:：]\s*(?=«|<<|```)"#)

        // Rule 2 — a task-meta preamble with an explicit clean/polish/format
        // verb, e.g. "Here's the cleaned text:", "This is the polished version:".
        // The verb keeps ordinary speech ("here's the plan:", "this is the bit:")
        // from ever matching. An optional leading interjection is tolerated, so
        // "Sure, here is the cleaned text:", "Okay! Here's the cleaned version:",
        // and dash/space-separated variants ("Sure — here's…", "Sure here is…")
        // are caught too — the clean-verb + framing token is still what triggers a
        // match, never the bare interjection.
        s = dropLeading(s, #"^(?:(?:sure|okay|ok|alright|certainly|absolutely|of course|got it|no problem|here you go)\b[^\n]{0,80}?[\s.!,:;…—–-]+)?(here(’|')?s|here is|this is|below is|i(’|')?ve|i have)\s+[^\n]{0,60}?\b(clean(ed)?|polished|formatted|reformatted|corrected)\b[^\n]{0,40}?[:：]\s*"#)

        // Unwrap fully-matched surrounding delimiters (possibly nested).
        return unwrap(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dropLeading(_ s: String, _ pattern: String) -> String {
        guard let match = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return s }
        return String(s[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips a matched surrounding pair only when it wraps the *entire* string,
    /// so an interior quote or a one-sided quotation is left untouched.
    ///
    /// "Entire" needs more than a prefix/suffix match (review 2026-08-26):
    /// dictated dialogue like `"Hello," she said. "Go."` starts AND ends with
    /// a quote, but those are two separate quotations — stripping them
    /// corrupts the user's own punctuation. So a pair only unwraps when the
    /// interior contains neither delimiter: a real packaging wrap encloses
    /// prose, not more of itself.
    private static func unwrap(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(String, String)] = [
            ("«", "»"), ("<<", ">>"), ("“", "”"), ("\"", "\""), ("```", "```"),
            // The on-device cleanup wraps its input in <transcript> tags; a
            // model that echoes the wrapper gets unwrapped here.
            ("<transcript>", "</transcript>"),
        ]
        var changed = true
        while changed {
            changed = false
            for (open, close) in pairs
            where s.count > open.count + close.count && s.hasPrefix(open) && s.hasSuffix(close) {
                let interior = String(s.dropFirst(open.count).dropLast(close.count))
                guard !interior.contains(open), !interior.contains(close) else { continue }
                s = interior.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return s
    }
}
