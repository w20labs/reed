import Foundation

/// Splits a dictation into the pieces the on-device cleanup model is actually
/// good at (2026-08-19): the identical prompt fixes "Um is can I trying to
/// understand…" perfectly as a lone sentence and leaves it untouched inside a
/// 40-word transcript — quality decays with input length, measurably, from
/// the second sentence on. So the AI tier cleans per sentence.
///
/// One exception, and it's load-bearing: spoken corrections cross sentence
/// boundaries ("Send the report to Bob. Wait, no, send it to Alice." must
/// resolve to Alice), so a sentence that OPENS with a correction cue — even
/// behind a filler — is glued to its predecessor and they're cleaned
/// together.
enum SentenceChunker {
    /// Split after sentence-final punctuation followed by whitespace.
    /// Decimals ("9.30") and domains ("w20labs.ai") never match — their dot
    /// has no following whitespace.
    private static let boundary = #"(?<=[.!?…])\s+"#

    /// A sentence that starts (after optional fillers) with one of these is
    /// the second half of a correction, not a new thought. Gluing a
    /// legitimate "Actually, …" or "No." to its predecessor is harmless —
    /// the chunk just gets one sentence longer.
    private static let cueOpening =
        #"(?i)^(?:(?:um+|uh+|well|oh)[,.\s]+)*(?:no|wait|actually|scratch that|sorry|i mean)\b"#

    /// Does this text open with a spoken-correction cue? Used across segment
    /// boundaries by overlapped cleanup (Coordinator+Overlap), the same rule
    /// that glues sentences within one split.
    static func opensWithCorrectionCue(_ text: String) -> Bool {
        text.range(of: cueOpening, options: .regularExpression) != nil
    }

    /// `coalesce` merges short adjacent sentences into one model call (see
    /// `coalesceShort`); off by default so the split stays pure per-sentence
    /// for every caller that doesn't opt in.
    /// `glueFragments` (cleanup-quality track, item 2, 2026-08-29): the
    /// recognizer writes a sentence end at any pause of ~700 ms or more, mid-
    /// sentence breaths included — "the onboarding flow still has. That
    /// issue where…", "we're going to. Spend the whole weekend" (field and
    /// bench, in every pipeline mode). A "sentence" that ends in a word no
    /// sentence ends in (an article, preposition, conjunction, auxiliary,
    /// subject pronoun) is a fragment: its mark is dropped and it is
    /// cleaned together with what follows.
    /// A model-sized piece and whether it continues the previous piece
    /// mid-sentence (a resplit of an oversized chunk). Cleanup gives such a
    /// piece a capital to work on and restores the seam on rejoin
    /// (finding 5, 2026-08-29: the model lowercased "wednesday" and
    /// invented "the. Date" at fragment boundaries).
    struct Chunk: Equatable {
        let text: String
        let continuesPrevious: Bool
    }

    static func chunks(_ text: String, coalesce: Bool = false, glueFragments: Bool = false) -> [Chunk] {
        var out: [Chunk] = []
        for unit in units(text, coalesce: coalesce, glueFragments: glueFragments) {
            for (i, piece) in resplit(unit).enumerated() {
                out.append(Chunk(text: piece, continuesPrevious: i > 0))
            }
        }
        return out
    }

    static func split(_ text: String, coalesce: Bool = false, glueFragments: Bool = false) -> [String] {
        units(text, coalesce: coalesce, glueFragments: glueFragments).flatMap(resplit)
    }

    /// A revision pair stays whole: cut at the model-size limit, two re-said
    /// sentences of up to `SentenceRevision.maxWords` each landed in
    /// different calls again (review of PR #29). Everything else is resplit.
    /// Kept whole only up to two of the longest revisable sentences: a cue
    /// sentence glued after the pair can make it longer still.
    private static func resplit(_ unit: Unit) -> [String] {
        unit.isRevision && wordCount(unit.text) <= 2 * SentenceRevision.maxWords ? [unit.text] : resplitOversized(unit.text)
    }

    /// One unit before the resplit, and whether it is a revision pair.
    private struct Unit {
        let text: String
        let isRevision: Bool
    }

    /// Sentences (with corrections and pause-fragments glued, short ones
    /// coalesced) — before the run-on resplit.
    private static func units(_ text: String, coalesce: Bool, glueFragments: Bool) -> [Unit] {
        let marker = "\u{1F}"
        let sentences = text
            .replacingOccurrences(of: boundary, with: marker, options: .regularExpression)
            .components(separatedBy: marker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard sentences.count > 1 else { return sentences.map { Unit(text: $0, isRevision: false) } }

        var chunks: [String] = []
        // A re-said sentence and the one it revises are one call ON THEIR
        // OWN: coalesced with a neighbour, the model left the pair as
        // spoken (research P01), while alone it resolves it (U01).
        var revisions: Set<Int> = []
        for sentence in sentences {
            if !chunks.isEmpty, SentenceRevision.revises(previous: lastSentence(of: chunks[chunks.count - 1]), next: sentence) {
                chunks[chunks.count - 1] += " " + sentence
                revisions.insert(chunks.count - 1)
            } else if !chunks.isEmpty,
               sentence.range(of: cueOpening, options: .regularExpression) != nil {
                chunks[chunks.count - 1] += " " + sentence
            } else if glueFragments, let last = chunks.last, endsInNonFinalWord(last),
                      wordCount(last) + wordCount(sentence) <= maxChunkWords {
                // Under the resplit cap on purpose: a glued chunk that then
                // gets resplit opens its fragments lowercase, and the model
                // lowercases proper nouns in such fragments (step 1 finding).
                chunks[chunks.count - 1] = dropTerminalMark(last) + " " + lowercasingFirstWord(sentence)
            } else {
                chunks.append(sentence)
            }
        }
        // Coalesce BEFORE the run-on resplit (long-input A/B, 2026-08-27):
        // a resplit fragment inherits the original sentence's terminal mark,
        // so merging after resplit glued "so we can … Monday." (a lowercase-
        // starting fragment) onto the next sentence — and the model, seeing
        // a chunk that opens lowercase, lowercased everything in it, proper
        // nouns included. Only whole sentences may merge; fragments never.
        let merged = coalesce ? coalesceShort(chunks, keepingAlone: revisions) : chunks
        let revised = Set(revisions.map { chunks[$0] })
        return merged.map { Unit(text: $0, isRevision: revised.contains($0)) }
    }

    /// Latency step 1 (2026-08-27, "where the second goes"): every model call
    /// pays a ~600 ms floor regardless of input length (bench: <60-char
    /// sentences 616 ms, >110-char 555 ms), and one call per sentence made a
    /// four-sentence clip cost four floors. Short ADJACENT sentences are
    /// merged into one call up to these ceilings — chosen from the same
    /// bench, where a 116-char sentence cleaned fine in one call. The
    /// ceilings are deliberately conservative: per-sentence cleaning exists
    /// because quality decayed on long input (2026-08-19), so the quality
    /// suites, not latency, decide whether these ever grow.
    static let coalesceMaxSentences = 2
    static let coalesceMaxChars = 150

    /// Merge runs of short, PUNCTUATION-TERMINATED sentences (an unterminated
    /// trailing sentence is left alone). Runs before the resplit, so every
    /// input here is a whole sentence — never a run-on fragment. A chunk that
    /// already glued a correction ("…Bob. Wait, no, Alice.") counts as one
    /// sentence; the merge rule sees chunks, not marks. The word cap keeps a
    /// merged pair under `maxChunkWords`, so coalescing can never produce a
    /// chunk the resplit would then cut back apart.
    static func coalesceShort(_ pieces: [String], keepingAlone alone: Set<Int> = []) -> [String] {
        var out: [String] = []
        var groupSentences = 0
        for (index, piece) in pieces.enumerated() {
            let terminated = piece.last.map { ".!?…".contains($0) } ?? false
            if alone.contains(index) {
                out.append(piece)
                groupSentences = coalesceMaxSentences
                continue
            }
            if let last = out.last, groupSentences > 0, groupSentences < coalesceMaxSentences,
               terminated, endsWithMark(last),
               last.count + 1 + piece.count <= coalesceMaxChars,
               wordCount(last) + wordCount(piece) <= maxChunkWords {
                out[out.count - 1] = last + " " + piece
                groupSentences += 1
            } else {
                out.append(piece)
                groupSentences = terminated ? 1 : 0
            }
        }
        return out
    }

    /// Words no English sentence ends in. Deliberately excludes anything a
    /// sentence CAN end in even if it rarely does: object pronouns ("ship
    /// it", "thank you"), demonstratives ("look at this"), particles ("come
    /// in", "it's over"), degree adverbs ("not really"), "do" ("please do").
    /// A missed glue keeps the status quo; a false glue only re-punctuates.
    static let nonFinalWords: Set<String> = [
        "a", "an", "the", "my", "your", "our", "their", "his",
        "i", "we", "he", "they",
        "and", "or", "but", "nor", "because", "although", "though", "while", "whereas",
        "if", "unless", "until", "than", "whether", "that", "which", "who", "whom", "whose",
        "is", "are", "was", "were", "be", "been", "being", "am", "has", "have", "had",
        "does", "did", "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "to", "of", "at", "from", "into", "onto", "between", "during", "without", "across", "per", "via", "as", "very"
    ]

    /// True when the sentence's last word (terminal mark ignored, contractions
    /// folded) is one no sentence ends in.
    static func endsInNonFinalWord(_ sentence: String) -> Bool {
        let stripped = dropTerminalMark(sentence)
        // "Scratch that." is a whole correction cue, not a sentence cut off
        // after "that": gluing it on wrote "Scratch that we will leave…" and
        // hid the cue from the model (third review of PR #29).
        if stripped.range(of: #"(?i)\bscratch\s+that$"#, options: .regularExpression) != nil { return false }
        guard let last = stripped.split(whereSeparator: \.isWhitespace).last else { return false }
        let word = last.lowercased().replacingOccurrences(of: "’", with: "'")
            .filter { $0.isLetter || $0 == "'" }
        // "we're", "it's", "I'll" — the pronoun half decides.
        let base = word.split(separator: "'").first.map(String.init) ?? word
        return nonFinalWords.contains(base)
    }

    /// The glued sentence's first word was capitalized only because the
    /// recognizer wrote a sentence end before it. "I" and its contractions,
    /// and acronyms ("ECS"), keep their case; a proper noun loses it and the
    /// model is expected to restore it — the gate is case-blind.
    private static func lowercasingFirstWord(_ text: String) -> String {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return text }
        let word = String(first)
        let isIForm = word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")
        let isAcronym = word.count > 1 && word.allSatisfy { $0.isUppercase || $0.isNumber || $0.isPunctuation }
        guard !isIForm, !isAcronym, let head = word.first, head.isUppercase else { return text }
        return String(head).lowercased() + text.dropFirst()
    }

    /// The sentences as marked, before any gluing or coalescing.
    static func sentences(_ text: String) -> [String] {
        text.replacingOccurrences(of: boundary, with: "\u{1F}", options: .regularExpression)
            .components(separatedBy: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The last sentence of a chunk that may already hold several.
    private static func lastSentence(of chunk: String) -> String {
        chunk.replacingOccurrences(of: boundary, with: "\u{1F}", options: .regularExpression)
            .components(separatedBy: "\u{1F}").last ?? chunk
    }

    private static func dropTerminalMark(_ text: String) -> String {
        var out = Substring(text)
        while let last = out.last, ".!?…".contains(last) { out = out.dropLast() }
        return String(out)
    }

    private static func endsWithMark(_ text: String) -> Bool {
        text.last.map { ".!?…".contains($0) } ?? false
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Above this, a chunk is outside the model's working range. The
    /// sentence split depends on the ASR writing punctuation — and a long
    /// dictation Whisper transcribes WITHOUT any collapses into one giant
    /// chunk, defeating per-sentence cleaning exactly when it matters most
    /// (field failure 2026-08-26: a 53 s dictation, zero punctuation, one
    /// 123-word chunk whose model output the acceptance nets rejected
    /// wholesale — the user got a raw run-on).
    private static let maxChunkWords = 24
    /// Never cut earlier than this — a soft break in the first few words is
    /// an opener ("And then…"), not a boundary.
    private static let minCutWords = 10
    /// Connectives a run-on naturally pivots on. A cut BEFORE one of these
    /// reads as the sentence boundary the speaker implied but the ASR never
    /// wrote; the model then cleans each piece and closes it normally.
    private static let softBreaks: Set<String> = [
        "and", "but", "so", "also", "then", "because", "which", "when", "could",
    ]

    /// Re-split one oversized chunk into model-sized windows: prefer the last
    /// soft-break word inside the window, fall back to a hard cut. A tiny
    /// tail is glued to its predecessor rather than closed as its own
    /// "sentence".
    private static func resplitOversized(_ chunk: String) -> [String] {
        var words = chunk.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > maxChunkWords else { return [chunk] }
        var pieces: [String] = []
        while words.count > maxChunkWords {
            var cut = maxChunkWords
            for i in stride(from: maxChunkWords - 1, through: minCutWords, by: -1)
            where softBreaks.contains(words[i].lowercased()) {
                cut = i
                break
            }
            pieces.append(words[0..<cut].joined(separator: " "))
            words.removeFirst(cut)
        }
        if words.count < 5, var last = pieces.popLast() {
            last += " " + words.joined(separator: " ")
            pieces.append(last)
        } else {
            pieces.append(words.joined(separator: " "))
        }
        return pieces
    }
}
