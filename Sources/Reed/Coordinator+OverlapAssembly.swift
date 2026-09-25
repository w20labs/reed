import Foundation

/// Joining overlapped segments back into one text (latency step 2). A pause
/// is usually a sentence boundary — unless the head ends in a word no
/// sentence ends in, in which case it was a breath; a cap cut never is — it landed inside a sentence,
/// so the halves on either side of it were cleaned as if each were a whole
/// sentence and carry a spurious break ("the. Blog", run-on bench
/// 2026-08-28). At a cap boundary the two halves are re-joined textually —
/// the pre-roll's duplicated words trimmed, the head's terminal punctuation
/// dropped, the next half's opening capital lowered. No model call: both
/// halves were already cleaned, and a re-clean cost ~0.9 s per cut at
/// release (run-on 1.5 → 3.2 s) for the same words.
extension Coordinator {
    /// One cleaned segment and how it ended (nil: the tail).
    struct Piece: Equatable {
        let text: String
        let sealedBy: SpeechSegmenter.Reason?
    }

    /// The two sides of a cap cut after the pre-roll's duplicate is removed.
    struct Seam: Equatable {
        let head: String
        let next: String
        /// Words dropped from the seam (duplicate + junk); 0 = untouched.
        let removed: Int
    }

    /// Longest run of words a pre-roll can duplicate (300 ms ≈ 1–2 words).
    static let maxOverlapWords = 3

    /// A seam verdict (decision 1) decides a pause seam ahead of the breath
    /// rule — never a cap cut, a restart or a correction cue, and only when
    /// applying it keeps every word. `verdicts` by piece index are a
    /// caller's (a test, a bench); otherwise `SeamRules` decides, or leaves
    /// the pause as it was. `onJoin` reports what happened at the seam
    /// BEFORE piece `index` (the local review copy, P16); nil callers see
    /// identical output.
    static func assembleSegments(_ pieces: [Piece], verdicts: [Int: SeamMark] = [:],
                                 onJoin: ((Int, ReviewRecord.JoinDecision) -> Void)? = nil) async -> String {
        let rules = FeatureFlags.shared.isEnabled(SeamRules.flag, default: SeamRules.flagDefault)
        var out: [String] = []
        var previousBoundary: SpeechSegmenter.Reason?
        for (index, piece) in pieces.enumerated() {
            defer { previousBoundary = piece.sealedBy }
            guard let prev = out.last else {
                if !piece.text.isEmpty { out.append(piece.text) }
                continue
            }
            let boundary = previousBoundary
            if boundary == .cap {
                let seam = trimOverlap(head: prev, next: piece.text)
                guard !seam.next.isEmpty else { onJoin?(index, .absorbed); continue }
                out[out.count - 1] = joinAcrossCut(seam.head, seam.next, lowercaseFirst: seam.removed == 0)
                onJoin?(index, .capSeam)
            } else if !piece.text.isEmpty, let seam = RestartLicence.crossSeamRestart(head: prev, next: piece.text) {
                // A restart split across a pause ("hi my name is. | My name
                // is Aram.", field 2026-09-04): the abandoned start goes with
                // the head's mark, under the same licence — and the same
                // gate — as within a chunk; the casing follows the evidence.
                out[out.count - 1] = seam.joined
                onJoin?(index, .restartCollapsed)
            } else if !piece.text.isEmpty, !SentenceChunker.opensWithCorrectionCue(piece.text),
                      let mark = verdicts[index] ?? (rules ? SeamRules.verdict(head: prev, next: piece.text) : nil),
                      let joined = SeamRules.apply(mark, head: prev, next: piece.text) {
                // What the pause was — punctuation and one capital, the
                // same words, gate-checked in `apply`.
                out[out.count - 1] = joined
                onJoin?(index, mark.joinDecision)
            } else if !piece.text.isEmpty, SentenceChunker.endsInNonFinalWord(prev) {
                // A pause seal on a breath, not a sentence end ("we are going
                // to… | spend the whole weekend", field 2026-08-29): the same
                // fragment rule the chunker applies within a segment
                // (cleanup-quality item 2), joined textually like a cap seam.
                out[out.count - 1] = joinAcrossCut(prev, piece.text, lowercaseFirst: true)
                onJoin?(index, .gluedBreath)
            } else if SentenceChunker.opensWithCorrectionCue(piece.text) {
                // A spoken correction crossing a pause ("…Bob. [pause] Wait,
                // no, Alice.") resolves only if both sides are cleaned
                // together, exactly as SentenceChunker glues them within a
                // segment.
                out[out.count - 1] = await LocalCleanup.$chunkSpan.withValue([index - 1, index]) {
                    await recleanAcrossPause(prev, piece.text)
                }
                onJoin?(index, .recleanedAcrossCue)
            } else if !piece.text.isEmpty {
                out.append(piece.text)
                onJoin?(index, .sentenceEnd)
            }
        }
        return out.joined(separator: " ")
    }

    /// Re-clean the last sentence of `head` with the first of `next` (a
    /// correction cue crossing a pause).
    static func recleanAcrossPause(_ head: String, _ next: String) async -> String {
        let headSentences = SentenceChunker.split(head)
        let nextSentences = SentenceChunker.split(next)
        guard let last = headSentences.last, let first = nextSentences.first else {
            return [head, next].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let joined = await LocalCleanup.apply(to: last + " " + first)
        return (headSentences.dropLast() + [joined] + nextSentences.dropFirst()).joined(separator: " ")
    }

    /// Join the halves of a sentence a cap cut split: drop the head's
    /// terminal punctuation and, when no pre-roll word was trimmed, lower
    /// the next half's opening capital — the recognizer capitalized it only
    /// because it opened a segment. ("I" and its contractions keep their case.)
    nonisolated static func joinAcrossCut(_ head: String, _ next: String, lowercaseFirst: Bool) -> String {
        var last = head
        while let ch = last.last, ".!?…".contains(ch) { last.removeLast() }
        var first = next
        if lowercaseFirst, let ch = first.first, ch.isUppercase,
           !first.hasPrefix("I ") && !first.hasPrefix("I'") && first != "I" {
            first = ch.lowercased() + first.dropFirst()
        }
        return [last, first].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Junk the recognizer can put around the duplicate: a phrase-completion
    /// hallucinated at the head's truncated END ("we're going to start" for
    /// "we're going to"; Parakeet: "we are going to be able to", finding 2
    /// of the 2026-08-29 rerun), or a mis-heard word at the next's START
    /// ("to it" for "it") — run-on bench 2026-08-28.
    static let maxOverlapJunkWords = 3

    /// Remove the words the pre-roll duplicated across a cap cut. The
    /// longest run of up to `maxOverlapWords` that ends the head and starts
    /// the next (case- and punctuation-insensitive) is kept once, on the
    /// head side, and dropped from the next together with any junk around it — up to `maxOverlapJunkWords`
    /// on either side, but fewer junk words than matched ones, unless the
    /// junk is a single short function word. The pre-roll audio IS the
    /// head's tail, so whatever the recognizer made of it is a duplicate.
    nonisolated static func trimOverlap(head: String, next: String) -> Seam {
        let headWords = head.split(separator: " ").map(String.init)
        let nextWords = next.split(separator: " ").map(String.init)
        func norm(_ word: String) -> String {
            word.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        // The pre-roll audio IS the head's tail, so a two-word match at the
        // seam is strong evidence; up to three junk words may then go.
        // A single-word match tolerates one short function word.
        func junkAllowed(_ words: [String], matched: Int) -> Bool {
            if matched >= 2 { return words.count <= Self.maxOverlapJunkWords }
            return words.isEmpty || (words.count == 1 && norm(words[0]).count <= 3)
        }
        let junkMax = Self.maxOverlapJunkWords
        for count in stride(from: Self.maxOverlapWords, through: 1, by: -1) {
            for headJunk in 0...junkMax where headWords.count >= count + headJunk {
                let tailEnd = headWords.count - headJunk
                let tail = headWords[(tailEnd - count)..<tailEnd].map(norm)
                guard !tail.contains("") else { continue }
                for nextJunk in 0...junkMax where nextWords.count >= count + nextJunk {
                    let lead = nextWords[nextJunk..<(nextJunk + count)].map(norm)
                    guard tail == lead else { continue }
                    let junk = Array(headWords[tailEnd...]) + Array(nextWords[..<nextJunk])
                    guard junkAllowed(junk, matched: count) else { continue }
                    return Seam(head: headWords[..<tailEnd].joined(separator: " "),
                                next: nextWords[(nextJunk + count)...].joined(separator: " "),
                                removed: headJunk + nextJunk + count)
                }
            }
        }
        return Seam(head: head, next: next, removed: 0)
    }
}
