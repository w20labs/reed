import Foundation

/// The one rule for what a spoken restart is (cleanup decision 2, approved
/// 2026-09-04): a phrase the speaker abandoned and said again right away.
/// Shared by the gate (which licenses the model's deletion of one), the
/// rules pass (which collapses one itself) and seam assembly (which
/// collapses one split across a pause) — never a second approximation that
/// can drift. `StumbleDetector` is a routing HINT for the repair prompt, not
/// a licence; nothing edits on its word.
///
/// Strong phrase evidence only: two to eight words, re-spoken immediately.
/// A single repeated word is never a restart here — a stutter, a
/// function-word slip or emphasis ("very very", "no no") are judged word by
/// word in the gate, and never collapsed by the deterministic passes. An
/// "X and X and X" chain ("again and again and again", "one by one by one")
/// is intentional and stays. Within a chunk a restart never crosses a
/// sentence mark ("Never share it. Never share it outside the team." is two
/// sentences); across a pause seam the recognizer's mark IS the seam.
///
/// Every deterministic proposal passes the gate's invariants before it is
/// applied (review 2026-09-06, P1): a collapse that would drop a negation,
/// a modal or a protected token is refused exactly as the model's would be.
enum RestartLicence {
    /// Longest abandoned start that still reads as a restart (gate round 2:
    /// a six-word false start — "can someone and Dana and Mar" — is one).
    static let maxWords = 8

    /// Repeats of these collapse silently in the gate ("the the"); a
    /// restarted function word must carry its next word with it.
    static let functionWords: Set<String> = [
        "the", "a", "an", "and", "it", "is", "to", "of", "in", "on", "at",
        "that", "this", "i", "we", "you", "so", "but", "for", "with"
    ]

    /// The link of an "X and X and X" chain — a two-word phrase that repeats
    /// on purpose when a THIRD copy begins right after the second.
    private static let chainLinks: Set<String> = ["and", "or", "by", "after", "upon", "to", "over"]

    /// A phrase that is itself a shorter unit repeated ("really really",
    /// "again and again and") is repetition, never a restart: collapsing it
    /// would shorten emphasis or a chain by a unit (review 2026-09-06, P2).
    static func isPeriodic(_ phrase: ArraySlice<String>) -> Bool {
        let words = Array(phrase)
        for unit in 1..<words.count where words.count % unit == 0 {
            if words.enumerated().allSatisfy({ $0.element == words[$0.offset % unit] }) { return true }
        }
        return false
    }

    /// "again and again and again", "one by one by one": the phrase is two
    /// words, one of them a link, and the alternation continues past the two
    /// copies — a third copy starts right after them, or the word before
    /// them is the phrase's second word (the same chain seen one word
    /// later). "go to go to Settings" is a restart: nothing continues.
    static func isChain(at index: Int, length: Int, tokens: [String]) -> Bool {
        guard length == 2 else { return false }
        let first = tokens[index], second = tokens[index + 1]
        guard chainLinks.contains(first) || chainLinks.contains(second) else { return false }
        let third = index + 2 * length
        if third < tokens.count, tokens[third] == first { return true }
        return index >= 1 && tokens[index - 1] == second
    }

    // MARK: - The gate's rule

    /// An abandoned start: the span's first word is re-spoken right after it
    /// ("tell them | tell the team", "I want to | I want to go"), or the span
    /// repeats a phrase said within two tokens before it ("we should
    /// probably | we should ship"). Adjacent single-word repeats never get
    /// here — they are stutters or emphasis, judged in the gate.
    static func isRestart(_ span: Range<Int>, tokens: [String]) -> Bool {
        let words = Array(tokens[span])
        guard words.count > 1, words.count <= maxWords, let first = words.first else { return false }
        let next = span.upperBound
        if next < tokens.count, tokens[next] == first {
            // A restarted function word must carry its next word with it
            // ("I want to | I want to", "the plan | the plan") — unless the
            // abandoned start is short ("on her | on the office"): a bare
            // "the" following a LONG span is coincidence, not a restart.
            if !functionWords.contains(first) { return true }
            if next + 1 < tokens.count, tokens[next + 1] == words[1] { return true }
            if words.count <= 3 { return true }
        }
        for gap in 0...2 {
            let end = span.lowerBound - gap
            let start = end - words.count
            guard start >= 0 else { break }
            if Array(tokens[start..<end]) == words { return true }
        }
        return false
    }

    // MARK: - The deterministic collapse (rules pass, seam assembly)

    /// The length of the phrase starting at `index` that is spoken again
    /// immediately after itself — the longest such length, two or more —
    /// or nil. `tokens` are folded comparison keys, one per word;
    /// `endsSentence(i)` says whether word `i` carries a sentence mark, and
    /// the abandoned copy must not (two sentences are not a restart).
    static func repeatedPhraseLength(at index: Int, tokens: [String],
                                     isRestartPair: (Range<Int>, Range<Int>) -> Bool = { _, _ in true }) -> Int? {
        var found: Int?
        for length in 2...maxWords {
            let end = index + 2 * length
            guard end <= tokens.count else { break }
            guard tokens[index..<(index + length)].elementsEqual(tokens[(index + length)..<end]) else { continue }
            if isPeriodic(tokens[index..<(index + length)]) { continue }
            if isChain(at: index, length: length, tokens: tokens) { continue }
            guard isRestartPair(index..<(index + length), (index + length)..<end) else { continue }
            found = length
        }
        return found
    }

    /// Collapse every restart in one chunk of text: the abandoned copy goes,
    /// the copy that continues stays with its own case and punctuation. A
    /// sentence-initial capital moves onto the kept copy.
    static func collapse(_ text: String) -> String {
        // Line by line: paragraph breaks are load-bearing (BasicCleanup keeps
        // them, the gate rejects invented ones) and a restart never spans one.
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { collapseLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func collapseLine(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let keys = words.map(key)
        var out: [String] = []
        var index = 0
        while index < words.count {
            // Both copies must be one phrase each (review 2026-09-06, round
            // 3): the abandoned copy with no sentence end at all, the kept
            // copy with none before its last word; neither ends in a closer.
            let pair: (Range<Int>, Range<Int>) -> Bool = { abandoned, kept in
                isOnePhrase(words[abandoned], allowLastMark: false) && isOnePhrase(words[kept], allowLastMark: true)
                    && !dropsADelimiter(words[abandoned]) && !opensADelimiter(words[kept])
            }
            guard !keys[index].isEmpty, let length = repeatedPhraseLength(at: index, tokens: keys, isRestartPair: pair) else {
                out.append(words[index])
                index += 1
                continue
            }
            var kept = Array(words[(index + length)..<(index + 2 * length)])
            if let dropped = words[index].drop(while: { openers.contains($0) }).first, dropped.isUppercase,
               let first = kept[0].first, first.isLowercase {
                kept[0] = String(first).uppercased() + kept[0].dropFirst()
            }
            // An opening quote or bracket on the abandoned copy moves to the kept one.
            let opener = leadingOpeners(words[index])
            if !opener.isEmpty, leadingOpeners(kept[0]).isEmpty { kept[0] = opener + kept[0] }
            out.append(contentsOf: kept)
            index += 2 * length
        }
        let proposal = out.joined(separator: " ")
        // The gate's invariants over the deterministic proposal, exactly as
        // over the model's: a refused collapse leaves the line as spoken.
        return CleanupGate.rejection(input: text, output: proposal, repairHint: false) == nil ? proposal : text
    }

    private static let openers = "\"'“‘«([{"
    private static let closers = "\"'”’»)]}"

    /// The opening quotes or brackets a word starts with ("\"tell" → "\"").
    static func leadingOpeners(_ word: String) -> String {
        String(word.prefix { openers.contains($0) })
    }

    /// Whether a word carries a closing quote or bracket at its end, with
    /// any punctuation after it (`me"`, `me",`, `me).` all close; the
    /// apostrophe inside `don't` does not).
    static func endsWithCloser(_ word: String) -> Bool {
        let trimmed = word.reversed().drop(while: { ".,!?;:…".contains($0) })
        return trimmed.first.map { closers.contains($0) } ?? false
    }

    /// Whether dropping these words would lose a delimiter: a closer on any
    /// of them, or an opener on any but the first (the first word's opener
    /// moves onto the kept copy) — review 2026-09-06, round 4.
    static func dropsADelimiter(_ words: ArraySlice<String>) -> Bool {
        if words.contains(where: endsWithCloser) { return true }
        return words.dropFirst().contains { !leadingOpeners($0).isEmpty }
    }

    /// Whether the kept copy opens a quotation or bracket: then the second
    /// copy is a quoted instruction ("Please say \"please say hello\""),
    /// not a restart — review 2026-09-06, round 5.
    static func opensADelimiter(_ words: ArraySlice<String>) -> Bool {
        words.contains { !leadingOpeners($0).isEmpty }
    }

    /// A copy the matcher may drop or keep: no sentence end inside it
    /// (`allowLastMark`: the copy's own last word may carry one — the kept
    /// copy ends a sentence, the head's abandoned copy carries the pause's
    /// mark), and no closing delimiter at its end, which would go with it.
    static func isOnePhrase(_ words: ArraySlice<String>, allowLastMark: Bool) -> Bool {
        guard let last = words.last else { return false }
        if words.dropLast().contains(where: endsSentence) { return false }
        if !allowLastMark, endsSentence(last) { return false }
        return true
    }

    /// Whether a whitespace word carries a sentence-final mark.
    static func endsSentence(_ word: String) -> Bool {
        var trimmed = Substring(word)
        while let last = trimmed.last, "\"'”’)".contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last else { return false }
        return ".!?…".contains(last)
    }

    /// A restart split across a pause seam, resolved: the head without the
    /// abandoned words (their mark included), joined to `next`.
    struct CrossSeam: Equatable {
        /// The head with the abandoned start removed ("" when it was all of it).
        let head: String
        /// The two sides joined: `next` keeps its opening capital when the
        /// abandoned copy proves it ("Dana Connor. | Dana Connor to join")
        /// or when it opens a sentence; it loses it when the abandoned copy
        /// was lowercase ("my name is. | My name is Aram").
        let joined: String
    }

    /// A restart split across a pause seam: the head's last two-to-eight
    /// words are what `next` opens with ("hi my name is. | My name is
    /// Aram."). Only the head's LAST line and the next piece's FIRST line
    /// take part — paragraphs elsewhere are untouched and never matched
    /// across — and only the mark at the pause itself may go: an abandoned
    /// copy that contains an earlier sentence end is two sentences (review
    /// 2026-09-06, P2). nil when there is no restart, or when the gate
    /// refuses the collapse (a lost negation across the seam, say).
    static func crossSeamRestart(head: String, next: String) -> CrossSeam? {
        var headLines = head.components(separatedBy: "\n")
        var nextLines = next.components(separatedBy: "\n")
        guard let headLine = headLines.popLast(), let nextLine = nextLines.first else { return nil }
        nextLines.removeFirst()
        guard let seam = crossSeamRestartLine(head: headLine, next: nextLine) else { return nil }
        let joined = (headLines + [seam.joined] + nextLines).joined(separator: "\n")
        let kept = (headLines + [seam.head]).joined(separator: "\n")
        return CrossSeam(head: kept, joined: joined)
    }

    private static func crossSeamRestartLine(head: String, next: String) -> CrossSeam? {
        let headWords = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let nextWords = next.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let headKeys = headWords.map(key), nextKeys = nextWords.map(key)
        var found: Int?
        for length in 2...maxWords where length <= headKeys.count && length <= nextKeys.count {
            let start = headKeys.count - length
            guard headKeys[start...].elementsEqual(nextKeys[..<length]), !headKeys[start...].contains("") else { continue }
            if isPeriodic(headKeys[start...]) { continue }
            // Only the pause's own mark on the abandoned copy, none inside the
            // kept copy before its last word, no closer going with the
            // abandoned copy (review 2026-09-06, rounds 2 and 3).
            guard isOnePhrase(headWords[start...], allowLastMark: true),
                  isOnePhrase(nextWords[..<length], allowLastMark: true),
                  !dropsADelimiter(headWords[start...]), !opensADelimiter(nextWords[..<length]) else { continue }
            // The chain test sees one word before the abandoned copy and the whole next line.
            let before = start > 0 ? 1 : 0
            if isChain(at: before, length: length, tokens: Array(headKeys[(start - before)...]) + nextKeys) { continue }
            found = length
        }
        guard let found else { return nil }
        let kept = headWords[..<(headWords.count - found)].joined(separator: " ")
        let abandonedFirst = headWords[headWords.count - found]
        var rest = nextWords
        // The case evidence is the abandoned copy's first LETTER, past any opening quote.
        if kept.isEmpty == false, let dropped = abandonedFirst.drop(while: { openers.contains($0) }).first, dropped.isLowercase,
           let first = rest[0].first, first.isUppercase, rest[0] != "I", !rest[0].hasPrefix("I'"), !rest[0].hasPrefix("I’") {
            rest[0] = String(first).lowercased() + rest[0].dropFirst()
        }
        let opener = leadingOpeners(abandonedFirst)
        if !opener.isEmpty, leadingOpeners(rest[0]).isEmpty { rest[0] = opener + rest[0] }
        let joined = (kept.isEmpty ? [] : [kept]) + [rest.joined(separator: " ")]
        let proposal = joined.joined(separator: " ")
        guard CleanupGate.rejection(input: head + " " + next, output: proposal, repairHint: false) == nil else { return nil }
        return CrossSeam(head: kept, joined: proposal)
    }

    /// One word's comparison key: lowercased, letters/digits only, so
    /// "Tell," and "tell" match and "don't"/"dont" match.
    static func key(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'")
            .filter { $0.isLetter || $0.isNumber }
    }
}
