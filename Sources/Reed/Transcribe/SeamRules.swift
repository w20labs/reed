import Foundation
import NaturalLanguage

/// What a pause between two overlapped segments turned out to be.
enum SeamMark: String, Codable, CaseIterable, Sendable {
    /// The head is a complete sentence; the next begins a new one.
    case period
    /// The next continues the head as a clause or a list item.
    case comma
    /// The pause fell inside a phrase: one run of words.
    case nothing
}

/// Seam decisions (cleanup decision 1, DECIDED 2026-09-07, narrowed). A
/// pause seals a segment, each half is cleaned as a whole sentence, and
/// assembly kept every pause as a sentence end unless the head ended in a
/// word no sentence ends in (the breath rule); cleanup never looked across
/// the seam. The decided model judge — one constrained question per seam —
/// was built and measured at chance in every phrasing on the on-device
/// model (shelved 2026-09-07, recoverable in Git), so a seam is decided by
/// a deterministic rule that fires only on strong evidence and otherwise
/// leaves the pause exactly as before. A verdict moves a mark and at most
/// one capital, never a word; `apply` checks that and runs the gate.
///
/// The one rule: a short head sentence that OPENS a subordinate clause and
/// does not close it ("If we ship on Friday." | "We lose the weekend.") —
/// one verb, no second clause — is not a sentence; the pause is a comma. Everything else — a conjunction opening
/// the next piece ("We need speed." | "And reliability."), a clause after
/// the main one ("We delayed it." | "Because the tests failed."), a period
/// before "But" — stays as spoken: those are often right as they are.
enum SeamRules {
    /// Remote flag, default OFF until the reviewed corpus shows the rule
    /// corrects more seams than it breaks (`SeamRulesBenchTests`; review
    /// 2026-09-07). Local override:
    ///   defaults write com.local.reed reed.flagOverride.cleanup_seam_rules -bool YES
    static let flag = "cleanup_seam_rules"
    static let flagDefault = false

    /// Words that open a subordinate clause when they open a sentence and
    /// nothing else: "once", "until", "before", "after" also open a
    /// complete sentence as adverbs or prepositions ("Before long we had a
    /// working build.", review 2026-09-07) and are out.
    static let clauseOpeners: Set<String> = [
        "if", "unless", "when", "whenever", "while", "although", "though"
    ]
    /// An open subordinate clause has a SUBJECT right after its opener —
    /// "if we…", "when the build…" — where an instruction has none ("If in
    /// doubt ask me", "While waiting read this", review 2026-09-07). A main
    /// clause inside the head shows as a second verb ("If the build passes
    /// the release goes out", "When the build passes we deploy it") or an
    /// imperative ("If it ain't broke don't fix it"): the sentence is
    /// closed, no comma. Verbs come from the system lexical tagger, which
    /// misses some ("restarts" as a noun, "say" in "If you see Bob say
    /// hi"), so the clause must also be short: a main clause hiding inside
    /// `maxClauseWords` words needs a mis-tag within three of them. Longer
    /// heads stay as spoken.
    private static let imperatives: Set<String> = ["don't", "let's", "please"]
    static let maxClauseWords = 5
    private static let subjectPronouns: Set<String> = ["i", "we", "you", "they", "he", "she", "it"]
    /// "there" is a subject only before a form of "be" ("there is time"),
    /// not in "While there take photos" (review 2026-09-07).
    private static let beForms: Set<String> = ["is", "are", "was", "were", "'s", "'re", "will", "'ll", "wo", "ai"]
    /// What may follow the opener in an open clause. A word the tagger
    /// reads as anything else — an interjection ("say" in "If you agree say
    /// yes"), an unknown — is a verb it may have missed: no evidence.
    private static let clauseClasses: Set<NLTag> = [
        .noun, .verb, .adjective, .adverb, .pronoun, .determiner, .particle, .preposition, .number, .conjunction
    ]
    private static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "our", "your", "their", "his", "her", "its", "some", "every", "each", "no"
    ]
    /// Auxiliaries and modals: a verb after one of these is the same
    /// group ("were generating", "do n't fix", "'ll merge"); two other
    /// verbs in a row are two ("While waiting read this").
    private static let auxiliaries: Set<String> = [
        "be", "am", "is", "are", "was", "were", "been", "being", "have", "has", "had", "having", "do", "does", "did",
        "can", "could", "will", "would", "shall", "should", "may", "might", "must", "ai", "ca", "wo", "sha",
        "'re", "'s", "'ve", "'ll", "'d", "'m"
    ]
    /// A second word that makes the opener a question ("When did it
    /// break"), not a clause — the rule stays out of questions the
    /// recognizer left without a mark.
    private static let questionShapes: Set<String> = [
        "did", "do", "does", "is", "are", "was", "were", "will", "can", "could", "should", "would", "have", "has", "had"
    ]
    /// The head clause needs this many words before the rule trusts it.
    static let minClauseWords = 3

    /// The rule's verdict for the pause between `head` and `next`, or nil:
    /// nothing is known, the pause stays what it was — including a head
    /// the breath rule already joins ("If we want to." | "Ship on
    /// Friday…"), which has the stronger evidence and keeps precedence.
    static func verdict(head: String, next: String) -> SeamMark? {
        guard let lastLine = lines(head).last, let firstLine = lines(next).first,
              let sentence = SentenceChunker.split(lastLine).last, !firstLine.isEmpty else { return nil }
        let clause = sentence.trimmingCharacters(in: .whitespaces)
        guard clause.last == ".", !clause.dropLast().contains(where: { ".!?…,;:".contains($0) }),
              !SentenceChunker.endsInNonFinalWord(clause) else { return nil }
        let words = clause.split(whereSeparator: \.isWhitespace).map { key(String($0)) }
        guard (minClauseWords...maxClauseWords).contains(words.count), let opener = words.first, clauseOpeners.contains(opener),
              !questionShapes.contains(words[1]), isOpenClause(clause) else { return nil }
        return .comma
    }

    /// A subject after the opener, exactly one verb group, no imperative:
    /// a clause left open. No verb found at all is no evidence — the
    /// tagger did not understand the clause — and the pause stays.
    static func isOpenClause(_ clause: String) -> Bool {
        let words = clause.split(whereSeparator: \.isWhitespace).map { key(String($0)) }
        guard !words.dropFirst().contains(where: { imperatives.contains($0) }) else { return false }
        let tagged = tags(of: clause)
        guard tagged.count >= 2, hasSubject(tagged.dropFirst()),
              tagged.dropFirst().allSatisfy({ $0.tag.map(clauseClasses.contains) == true }) else { return false }
        return verbGroups(tagged) == 1
    }

    /// The tagger's reading: (word, lexical class) per word.
    static func tags(of text: String) -> [(word: String, tag: NLTag?)] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var out: [(String, NLTag?)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            out.append((key(String(text[range])), tag))
            return true
        }
        return out
    }

    /// A subject pronoun, or a determiner and its noun, opening the body.
    private static func hasSubject(_ body: ArraySlice<(word: String, tag: NLTag?)>) -> Bool {
        guard let first = body.first else { return false }
        if subjectPronouns.contains(first.word) { return true }
        guard let second = body.dropFirst().first else { return false }
        if first.word == "there" { return beForms.contains(second.word) }
        guard determiners.contains(first.word) else { return false }
        return second.tag == .noun || second.tag == .adjective
    }

    /// Verb groups: an auxiliary carries the verb after it ("were
    /// generating", "do n't fix"), an adverb inside a group does not split
    /// it, and any other verb starts a group of its own.
    static func verbGroups(_ tagged: [(word: String, tag: NLTag?)]) -> Int {
        var groups = 0
        var open = false   // the current group still accepts a verb
        for (word, tag) in tagged {
            switch tag {
            case .some(.verb):
                if !open { groups += 1 }
                open = auxiliaries.contains(word)
            case .some(.adverb):
                break
            default:
                open = false
            }
        }
        return groups
    }

    static func verbGroups(in text: String) -> Int { verbGroups(tags(of: text)) }

    private static func key(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'").filter { $0.isLetter || $0 == "'" }
    }

    /// Apply a verdict at the seam between `head` and `next`: the joined
    /// text, or nil when the result is not the same words — the gate's
    /// contract holds for this pass as for every other edit, and the caller
    /// then leaves the seam as it was. Only the head's last line and the
    /// next's first line meet; paragraph breaks on either side survive.
    static func apply(_ mark: SeamMark, head: String, next: String) -> String? {
        var headLines = lines(head), nextLines = lines(next)
        guard let last = headLines.last, let first = nextLines.first, !last.isEmpty, !first.isEmpty else { return nil }
        let joinedLine: String
        switch mark {
        case .period:
            let closed = endsWithTerminalMark(last) ? last : last + "."
            joinedLine = closed + " " + LocalCleanup.capitalizingFirst(first)
        case .comma:
            let open = dropTerminalMarks(last)
            let withComma = open.last.map { ",;:".contains($0) } == true ? open : open + ","
            joinedLine = withComma + " " + loweringClauseOpener(first)
        case .nothing:
            joinedLine = Coordinator.joinAcrossCut(last, first, lowercaseFirst: true)
        }
        headLines.removeLast()
        nextLines.removeFirst()
        let joined = (headLines + [joinedLine] + nextLines).joined(separator: "\n")
        let spoken = head + " " + next
        guard words(joined) == words(spoken),
              CleanupGate.rejection(input: spoken, output: joined, repairHint: false) == nil else { return nil }
        return joined
    }

    /// Words that carry a capital only because they opened a segment:
    /// pronouns, determiners, connectors, auxiliaries — none of which is
    /// also a given name ("Will is available", review 2026-09-07; `SeamRulesTests`
    /// holds the list against the common ones). Any other opening capital
    /// may be a name ("If the build passes, Dana can deploy") and stays.
    static let loweredOpeners: Set<String> = [
        "we", "you", "they", "he", "she", "it", "the", "a", "an", "this", "that", "these", "those",
        "my", "our", "your", "their", "his", "her", "its", "some", "any", "every", "each", "all", "no",
        "then", "there", "here", "so", "also", "just", "still", "only", "maybe", "please", "let's", "let",
        "do", "don't", "could", "should", "would", "we'll", "you'll", "they'll", "it's", "that's",
        "there's", "what", "which", "who", "how", "why", "where", "when", "and", "but", "or", "because"
    ]

    /// Lower the opening capital when the word is one that is never a name
    /// and only its first letter is capitalized — "IT" and "WHO" are
    /// acronyms, and their case is the evidence (review 2026-09-07).
    static func loweringClauseOpener(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let word = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? text
        guard !word.dropFirst().contains(where: \.isUppercase), loweredOpeners.contains(key(word)) else { return text }
        return first.lowercased() + text.dropFirst()
    }

    // MARK: - Text helpers

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The words alone — case and punctuation aside — for the identity
    /// check: a verdict may move a mark or a capital, never a word.
    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.map(String.init)
    }

    private static func endsWithTerminalMark(_ text: String) -> Bool {
        // A closer after the mark ("go.") still ends the sentence.
        text.reversed().first { !"\"'’”)]".contains($0) }.map { ".!?…".contains($0) } ?? false
    }

    private static func dropTerminalMarks(_ text: String) -> String {
        var out = text
        while let ch = out.last, ".!?…".contains(ch) { out.removeLast() }
        return out
    }
}

extension SeamMark {
    /// How the review copy names a seam a verdict decided.
    var joinDecision: ReviewRecord.JoinDecision {
        switch self {
        case .period: return .seamPeriod
        case .comma: return .seamComma
        case .nothing: return .seamNothing
        }
    }
}
