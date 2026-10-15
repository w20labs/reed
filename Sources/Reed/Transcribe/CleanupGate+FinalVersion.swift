import Foundation

/// The speaker's final version of a revision, and what cleanup may repair
/// inside a version (reviews 2-10 of PR #29). Every judgement here is made
/// from the source words as written — their identity, case and position —
/// so a formatting change in a proposal never changes it.
extension CleanupGate {
    /// The speaker's final version of a revision is never lost (reviews 2-4
    /// of PR #29). Versions are found in the INPUT — never from the
    /// deletion's alignment, which slides over repeated wording — as
    /// segments: split at any punctuation between words (periods, commas,
    /// semicolons, colons, dashes), and again wherever a segment's opening
    /// word recurs, for speech transcribed with no punctuation at all ("we
    /// were going to leave the office we are going to leave…"). Adjacent
    /// segments the chunker's revision rule links form a chain, and the LAST
    /// version must survive in context: as one run of the proposal's words
    /// (fifth review: checking only its changed words against the whole
    /// proposal let "Maya will call" supply "will", and missed a final
    /// version that only removes words — "We can approve… We approve…").
    /// A wrong split misses a chain (nothing is refused), it never invents
    /// one. Dropping a middle version keeps the final one and passes.
    static func losesFinalVersion(input: String, tokens: [GateVerdict.Token], keys: [String], output: [String]) -> Bool {
        let segments = versionSegments(input: input, tokens: tokens, keys: keys)
        var index = 0
        while index + 1 < segments.count {
            guard revisesSegment(segments[index], segments[index + 1]) else { index += 1; continue }
            var last = index + 1
            while last + 1 < segments.count, revisesSegment(segments[last], segments[last + 1]) { last += 1 }
            if !survives(segments[last], in: output.filter { !fillers.contains($0) }) { return true }
            index = last
        }
        return false
    }

    /// Whether `version` appears as one run of `output` (fillers already
    /// removed on both sides), as spoken or with any of the repairs cleanup
    /// may make inside it: a run that drops only repairable words of the
    /// version (a doubled function word, a stutter fragment, a restarted
    /// phrase) and matches it once both are repaired. Partial repairs pass;
    /// a dropped real word ("six" before "sixteen") does not.
    /// Whether `version` (source keys, with their capitals marks) survives
    /// as one run of `output`. What may be missing is decided by the SOURCE
    /// alone (`repairablePositions`: a doubled function word, a stutter
    /// fragment, a restarted phrase), and words are compared by identity, so
    /// a case change in the proposal never changes the verdict — "an ai air
    /// filter" may become "an AI air filter", and "an AI air filter" "an ai
    /// air filter" (tenth review of PR #29: repairing the source and the
    /// proposal independently judged "ai" twice, differently). Partial
    /// repairs pass; a dropped meaningful word does not.
    static func survives(_ version: [String], in output: [String]) -> Bool {
        let source = version.map(identity), droppable = repairablePositions(version)
        let shortest = version.count - droppable.count
        guard shortest > 0, shortest <= output.count else { return false }
        let outputs = output.map(identity)
        for length in shortest...min(version.count, output.count) {
            for start in 0...(output.count - length) where matches(Array(outputs[start..<(start + length)]), source, skipping: droppable) {
                return true
            }
        }
        return false
    }

    /// Whether `run` is `source` with some of the `skipping` positions left out.
    private static func matches(_ run: [String], _ source: [String], skipping: Set<Int>) -> Bool {
        var reachable = Set([0])   // run positions reachable after each source word
        for (index, word) in source.enumerated() {
            var next: Set<Int> = []
            for position in reachable {
                if position < run.count, run[position] == word { next.insert(position + 1) }
                if skipping.contains(index) { next.insert(position) }
            }
            reachable = next
            if reachable.isEmpty { return false }
        }
        return reachable.contains(run.count)
    }

    /// Two-letter words, which are never a stutter of the next word.
    private static let shortWords: Set<String> = [
        "a", "i", "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is", "it",
        "me", "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "up", "us", "we"
    ]

    /// A stutter: a fragment of at most two letters, no digits, not a word,
    /// that the next word starts with ("c cloud", "re rework", "l leave").
    /// "six sixteen", "ten tenth", "per person" are two words (sixth review
    /// of PR #29). Shared with the gate's own stutter rule.
    static func isStutter(_ word: String, before next: String) -> Bool {
        word.count <= 2 && word.count < next.count && next.hasPrefix(word)
            && !word.contains(where: \.isNumber) && !shortWords.contains(word)
    }

    /// One comparison key per token, by position. A word written in
    /// capitals ("AI", "PR", "UM") keeps a key of its own ("^ai"), so it is
    /// never a stutter, a filler or the same word as a lowercase occurrence
    /// elsewhere (seventh and eighth reviews of PR #29: a set of acronym
    /// spellings protected the lowercase fragment "pr" too, and "UM" was a
    /// filler). Negations, modals, cues, function words and auxiliaries keep
    /// their usual key whatever the case: "do NOT" is still a negation.
    /// A key without its capitals mark: identity, whatever the case. One
    /// exception: a capitalized word spelled like a filler ("UM", "ER")
    /// keeps its mark — lowercased, the rules pass would strip it as a
    /// filler, so "UM" → "um" is a change, not a case fix.
    static func identity(_ key: String) -> String {
        guard key.hasPrefix("^") else { return key }
        let word = String(key.dropFirst())
        return fillers.contains(word) ? key : word
    }

    static func caseKeys(_ text: String, tokens: [GateVerdict.Token]) -> [String] {
        tokens.map { token in
            let key = fold(token.text)
            let original = text[token.characters]
            guard original.count >= 2, original.contains(where: \.isLetter),
                  original.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "'" || $0 == "’" }) else { return key }
            let structural = negations.contains(key) || modals.contains(key) || modalVerbs.contains(key) || markers.contains(key)
                || RestartLicence.functionWords.contains(key) || auxiliaries.contains(key) || token.text.hasSuffix("n't")
            return structural ? key : "^" + key
        }
    }

    /// `words` without the stumbles cleanup repairs (`repairablePositions`).
    static func repaired(_ words: [String]) -> [String] {
        let droppable = repairablePositions(words)
        return words.indices.filter { !droppable.contains($0) }.map { words[$0] }
    }

    /// The positions cleanup may drop, judged from the words as written
    /// (keys with their capitals marks): a doubled function word or
    /// auxiliary ("the the", "will will" — a doubled content word is
    /// emphasis, "one one bedroom" is content, "had had" is grammar), a
    /// stutter fragment however often it repeats ("c c c change"; "AI" is no
    /// fragment, a lowercase "ai" beside "air" is), a restarted phrase.
    static func repairablePositions(_ words: [String]) -> Set<Int> {
        var droppable: Set<Int> = [], index = 0
        while index < words.count {
            if let length = RestartLicence.repeatedPhraseLength(at: index, tokens: words.map(identity)) {
                droppable.formUnion(index..<(index + length)); index += length; continue
            }
            let word = words[index]
            var next = index + 1
            while next < words.count, words[next] == word { next += 1 }
            if next < words.count, isStutter(word, before: identity(words[next])) {
                droppable.formUnion(index..<next); index = next; continue
            }
            if index + 1 < words.count, words[index + 1] == word, !grammaticalDoubles.contains(word),
               RestartLicence.functionWords.contains(word) || auxiliaries.contains(word) { droppable.insert(index) }
            index += 1
        }
        return droppable
    }

    private static func revisesSegment(_ earlier: [String], _ later: [String]) -> Bool {
        earlier.count >= 3 && later.count >= 2
            && SentenceRevision.revises(previous: earlier.joined(separator: " "), next: later.joined(separator: " "))
    }

    /// The input's words as candidate versions (fillers dropped).
    static func versionSegments(input: String, tokens: [GateVerdict.Token], keys: [String]) -> [[String]] {
        var marked: [[String]] = [[]]
        for index in keys.indices {
            if !fillers.contains(keys[index]) { marked[marked.count - 1].append(keys[index]) }
            guard index + 1 < keys.count else { break }
            let between = input[tokens[index].characters.upperBound..<tokens[index + 1].characters.lowerBound]
            if between.contains(where: { ".,;:!?…—–".contains($0) }) || between.contains(" - ") { marked.append([]) }
        }
        return marked.filter { !$0.isEmpty }.flatMap { segment -> [[String]] in
            guard let opening = segment.first else { return [] }
            var parts: [[String]] = [[]]
            for (offset, word) in segment.enumerated() {
                if offset > 0, word == opening, parts[parts.count - 1].count >= 3 { parts.append([]) }
                parts[parts.count - 1].append(word)
            }
            return parts
        }
    }
}
