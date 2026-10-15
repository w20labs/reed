import Foundation

/// An uncued spoken correction that crosses a sentence mark (natural
/// self-correction, 2026-10-14): the speaker says a sentence, then says it
/// again changed — "We were going to go. We are going to go." — or finishes
/// it again with a new ending — "…on Thursday. On Friday." The model can
/// only resolve that when it sees both, so the chunker (and the pause-seam
/// assembly) keep them in one call. Gluing decides only what the model
/// SEES together: what may be deleted is still the model's proposal under
/// the gate's licences, and a completed contrast ("We were going to go
/// yesterday. We are going to go tomorrow.") stays when the model keeps it.
enum SentenceRevision {
    /// Longer sentences are separate thoughts, not a quick re-say.
    static let maxWords = 16
    /// A re-said sentence keeps at least this share of its words in order.
    static let minSharedRatio = 0.6

    static func revises(previous: String, next: String) -> Bool {
        let before = keys(previous), after = keys(next)
        guard !before.isEmpty, !after.isEmpty, before.count <= maxWords, after.count <= maxWords else { return false }
        // A short completion: "On Friday." redoing the end of "I want to send
        // this on Thursday." — a tail of a longer sentence, never a whole
        // short one ("Short one. Short two.", "Call Sam. Call Priya too.").
        // It must replace the tail, not continue it: a word of the tail
        // changes ("He said \"tell me.\" Tell me more." changes nothing).
        if (2...3).contains(after.count), before.count >= 4,
           let start = before.indices.suffix(3).last(where: { before[$0] == after[0] }), start < before.count - 1 {
            let tail = Array(before[start...])
            return after.count <= tail.count + 1 && zip(tail, after).contains { $0 != $1 }
        }
        // A re-said sentence: most of it is the previous one, in order, and
        // something of the previous one changed — a sentence that only adds
        // to it ("Do not do it. Do not do it now.") elaborates, it does not
        // revise.
        guard after.count >= 3, after.count <= before.count + 3 else { return false }
        let shared = commonSubsequence(before, after)
        return shared >= 3 && shared < before.count && Double(shared) >= minSharedRatio * Double(after.count)
    }

    /// Across a pause seam: the head's last sentence and the next piece's first.
    static func revisesAcrossPause(head: String, next: String) -> Bool {
        guard let last = SentenceChunker.split(head).last, let first = SentenceChunker.split(next).first else { return false }
        return revises(previous: last, next: first)
    }

    private static func keys(_ sentence: String) -> [String] {
        sentence.split(whereSeparator: \.isWhitespace).map { RestartLicence.key(String($0)) }.filter { !$0.isEmpty }
    }

    private static func commonSubsequence(_ left: [String], _ right: [String]) -> Int {
        var row = Array(repeating: 0, count: right.count + 1)
        for word in left {
            var diagonal = 0
            for (column, other) in right.enumerated() {
                let above = row[column + 1]
                row[column + 1] = word == other ? diagonal + 1 : max(row[column + 1], row[column])
                diagonal = above
            }
        }
        return row[right.count]
    }
}
