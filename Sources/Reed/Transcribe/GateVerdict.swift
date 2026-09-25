import Foundation

/// Everything the gate found between an input and a proposal — every
/// deleted span with the licence that explains it or the fault it
/// carries, every added word, the negation and modal accounting, the
/// protected tokens that vanished, the newlines invented — and
/// `rejection`, the first failing check in the gate's fixed order,
/// exactly as `rejection(input:output:repairHint:)` has always
/// returned it (cleanup decision 3, step 1, 2026-09-08: a structured
/// verdict with unchanged decisions, so a later repair can know WHICH
/// edit offended and where it sits in the original characters).
struct GateVerdict: Equatable {
    /// One input token: its folded text (what alignment compares) and
    /// where it sits in the original string, characters untouched.
    struct Token: Equatable {
        let text: String
        let characters: Range<String.Index>
    }

    /// Why a deleted span is allowed.
    enum Licence: String, Equatable {
        /// A leading discourse opener or marker ("so", "okay", "no").
        case opener
        /// A re-spoken phrase, the shared restart rule.
        case restart
        /// Every token a filler, an aside, a stutter, a collapsed
        /// function-word or auxiliary repeat, a near repeat, or a marker.
        case incidental
        /// A structural deletion licensed by the repair hint or a marker beside it.
        case structural
    }

    /// Why a deleted span is refused.
    enum Fault: String, Equatable {
        /// A repeated content word was collapsed: emphasis, not a stumble.
        case emphasisRepeat
        /// A structural deletion that reaches the end of the input.
        case truncation
        /// A structural deletion with no licence.
        case unlicensed
        /// One structural span too many for one chunk.
        case tooMany
    }

    /// One deleted span of the edit map. `tokens` and `characters` come
    /// from the one alignment behind the whole verdict (deletions are
    /// disjoint and, with `additions`, reconstruct the proposal from the
    /// input); `window` is the span the gate classified — slid left over
    /// an equal neighbour for an LCS tie, as it always has — and may
    /// overlap another deletion's window. Restore from `tokens`; explain
    /// from `window`; `slid` says the two differ (review 2026-09-08).
    struct Deletion: Equatable {
        let tokens: Range<Int>
        let window: Range<Int>
        /// The original characters from the span's first token to its last.
        let characters: Range<String.Index>
        let licence: Licence?
        let fault: Fault?
        var slid: Bool { tokens != window }
    }

    /// One proposal token the alignment could not match to the input —
    /// the occurrence consistent with the input's order ("ship tomorrow"
    /// → "tomorrow ship tomorrow": the first "tomorrow", not the last).
    struct Addition: Equatable {
        /// Index into the proposal's tokens.
        let outputToken: Int
        let word: String
    }

    struct Negations: Equatable {
        let input: Int
        let output: Int
    }

    let rejection: CleanupGate.Rejection?
    let inputTokens: [Token]
    let deletions: [Deletion]
    let additions: [Addition]
    let negations: Negations
    let modalsMissing: Set<String>
    let modalsAdded: Set<String>
    let protectedMissing: [String]
    let newlinesAdded: Int

    /// The original characters a deletion covers.
    func original(of deletion: Deletion, in input: String) -> String {
        String(input[deletion.characters])
    }
}

extension CleanupGate {
    /// The input's tokens with their original character ranges: the same
    /// tokens `rawTokens` yields (letters, digits and apostrophes, case
    /// folded, ’ read as '), each anchored to where it came from.
    static func tokens(of text: String) -> [GateVerdict.Token] {
        var out: [GateVerdict.Token] = []
        var start: String.Index?
        var index = text.startIndex
        func close(at end: String.Index) {
            guard let from = start else { return }
            let raw = String(text[from..<end]).lowercased().replacingOccurrences(of: "’", with: "'")
            out.append(GateVerdict.Token(text: raw, characters: from..<end))
            start = nil
        }
        while index < text.endIndex {
            let ch = text[index]
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                if start == nil { start = index }
            } else {
                close(at: index)
            }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return out
    }
}
