import Foundation

/// A correction spoken at the end of a sentence, resolved by rule (field
/// 2026-10-06): "Meet at 7:00 PM, sorry, 5:00 PM." → "Meet at 5:00 PM." The
/// on-device model keeps the abandoned option there ("Meet at 7:00 PM."),
/// the gate rightly refuses it, and the dictation stays as spoken; a prompt
/// rule for it cost more than it fixed (it began deleting "I'm sorry").
///
/// Narrow on purpose. The whole tail after the cue must be one value, and
/// the words just before the cue a value of the same kind: a time, an
/// amount, a number, a weekday or an email, optionally after the same
/// preposition ("on Tuesday, I mean on Wednesday"). Anything else
/// ("left. Sorry, right.") is left to the model. The edit is deletion-only
/// and must pass the gate like any proposal.
enum TailCorrection {
    /// Longest first, so "no wait" is not read as "no".
    private static let cue = #"(?:no,? wait|wait,? no|actually,? no|scratch that|i mean|or rather|sorry|actually|rather|no)"#
    private static let cueSpan = #"[,.]?\s+\b"# + cue + #"\b[,.]?\s+"#
    private static let prepositions: Set<String> = ["at", "on", "for", "by", "to", "from", "until"]

    enum Kind: CaseIterable {
        case time, amount, number, weekday, email

        var pattern: String {
            switch self {
            case .time: return #"^\d{1,2}(?::\d{2})?\s?(?:[ap]\.?m\.?)$|^\d{1,2}:\d{2}$"#
            case .amount: return #"^[$€£]\d[\d,]*(?:\.\d+)?$"#
            case .number: return #"^\d[\d,]*(?:\.\d+)?%?$|^(?:one|two|three|four|five|six|seven|eight|nine|ten)$"#
            case .weekday: return #"^(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)$"#
            case .email: return #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
            }
        }

        static func of(_ value: String) -> Kind? {
            allCases.first { value.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        }
    }

    /// The text with every end-of-sentence value correction resolved, or the
    /// text untouched when there is none.
    static func apply(_ text: String) -> String {
        var changed = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let units = SentenceChunker.split(String(line))
            let resolved = units.map { unit -> String in
                guard let fixed = resolve(unit), CleanupGate.accepts(input: unit, output: fixed, repairHint: false) else { return unit }
                return fixed
            }
            guard resolved != units else { return String(line) }
            changed = true
            return resolved.joined(separator: " ")
        }
        return changed ? lines.joined(separator: "\n") : text
    }

    /// One sentence's correction, or nil.
    static func resolve(_ sentence: String) -> String? {
        var body = sentence.trimmingCharacters(in: .whitespaces)
        var close = ""
        if let last = body.last, ".!?".contains(last) { close = String(last); body.removeLast() }
        guard let cueRange = lastMatch(of: cueSpan, in: body) else { return nil }
        let headWords = body[..<cueRange.lowerBound].split(separator: " ").map(String.init)
        var tailWords = body[cueRange.upperBound...].split(separator: " ").map(String.init)
        var preposition: String?
        if let first = tailWords.first, prepositions.contains(first.lowercased()), tailWords.count > 1 {
            preposition = first; tailWords.removeFirst()
        }
        let tail = tailWords.joined(separator: " ")
        guard let kind = Kind.of(tail) else { return nil }
        for length in stride(from: min(3, headWords.count), through: 1, by: -1) {
            let start = headWords.count - length
            guard Kind.of(headWords[start...].joined(separator: " ")) == kind else { continue }
            var keep = Array(headWords[..<start])
            if let preposition {
                // "on Tuesday, I mean on Wednesday": the spoken preposition
                // must match the one it replaces, which goes with its value.
                guard keep.last?.lowercased() == preposition.lowercased() else { return nil }
                keep.removeLast()
            }
            return (keep + (preposition.map { [$0] } ?? []) + tailWords).joined(separator: " ") + close
        }
        return nil
    }

    private static func lastMatch(of pattern: String, in text: String) -> Range<String.Index>? {
        var found: Range<String.Index>?
        var searchStart = text.startIndex
        while let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive], range: searchStart..<text.endIndex) {
            found = range
            searchStart = range.upperBound
        }
        return found
    }
}
