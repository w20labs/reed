import Foundation

/// Spoken-restart patterns that route a chunk to the repair prompt
/// (repair-trigger round, 2026-08-29, docs/bench/repair_before.txt): as
/// isolated sentences the generic prompt left ten of twelve field stumbles
/// alone while the repair prompt fixed eight — it just was not chosen,
/// because `structuralReason` only knew doubled words, stutters, fillers
/// and one determiner pattern. These are the shapes it missed.
enum StumbleDetector {
    /// Function words repeat legitimately ("the X and the Y"); only a
    /// repeated content word within a few tokens is a restart.
    private static let functionWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by",
        "from", "as", "is", "are", "was", "were", "be", "it", "that", "this", "i", "we", "you",
        "he", "she", "they", "my", "our", "your", "his", "her", "their", "so", "if", "not", "no",
        "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "should",
        "very", "just", "also", "then", "than", "there", "here", "what", "which", "who", "how"
    ]

    /// A word or bigram spoken again a few tokens later ("tell them | tell
    /// the team", "on her | on the office", "can someone and Dana and Mar
    /// | can someone add"), or two adjacent words where one is a near-copy
    /// of the other ("does doesn't", "least latest", "One On").
    static func restart(_ text: String) -> String? {
        let tokens = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }
            .map { $0.replacingOccurrences(of: "’", with: "'") }
        guard tokens.count >= 3 else { return nil }
        func isContent(_ token: String) -> Bool { !functionWords.contains(token) && !token.contains("'") && token.count >= 3 }
        for i in tokens.indices {
            // A bigram with a content word in it, spoken again after two to
            // six abandoned tokens ("can someone and Dana and Mar | can
            // someone add"). "It is what it is" and "the plan is the plan"
            // repeat with one token between — idiom, not a restart.
            let bigramEnd = min(tokens.count - 1, i + 9)
            if i + 4 < bigramEnd, isContent(tokens[i]) || isContent(tokens[i + 1]) {
                let bigram = (tokens[i], tokens[i + 1])
                for later in (i + 4)..<bigramEnd where tokens[later] == bigram.0 && tokens[later + 1] == bigram.1 {
                    return "bigram-restart"
                }
            }
            // A content word spoken again with exactly one token between
            // ("tell them | tell the team"). Adjacent is the doubled-word
            // rule's; further apart is prose ("I think we should think").
            if i + 2 < tokens.count, isContent(tokens[i]), tokens[i + 2] == tokens[i], tokens[i + 1] != tokens[i] {
                return "word-restart"
            }
            // Adjacent near-duplicate: prefix or edit distance ≤ 2 on words of 3+.
            if i + 1 < tokens.count, isNearCopy(tokens[i], tokens[i + 1]) { return "near-word" }
        }
        return nil
    }

    static func isNearCopy(_ left: String, _ right: String) -> Bool {
        // A function word beside a longer word that starts with it is
        // ordinary prose ("there are areas", "the theory", "can cancel",
        // "his history" — review 2026-08-30, R4); the only near-copy a
        // function word makes is its own contraction ("does doesn't").
        if functionWords.contains(left) || functionWords.contains(right) {
            let short = left.count <= right.count ? left : right
            let long = left.count <= right.count ? right : left
            return long.hasPrefix(short) && ["n't", "'s", "'re", "'ll", "'ve", "'d"].contains(String(long.dropFirst(short.count)))
        }
        let lhs = left.replacingOccurrences(of: "'", with: ""), rhs = right.replacingOccurrences(of: "'", with: "")
        // Two-letter prefixes are everywhere in prose ("Toby to", "of office",
        // "on one"): the shorter word needs three letters, the longer four.
        guard lhs != rhs, min(lhs.count, rhs.count) >= 3, max(lhs.count, rhs.count) >= 4 else { return false }
        if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return true }
        guard lhs.count >= 5, rhs.count >= 5, abs(lhs.count - rhs.count) <= 2 else { return false }
        return editDistance(lhs, rhs) <= 2
    }

    private static func editDistance(_ left: String, _ right: String) -> Int {
        let lhs = Array(left), rhs = Array(right)
        var row = Array(0...rhs.count)
        for i in 1...lhs.count {
            var prev = row[0]; row[0] = i
            for col in 1...rhs.count {
                let cur = row[col]
                row[col] = min(row[col] + 1, row[col - 1] + 1, prev + (lhs[i - 1] == rhs[col - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[rhs.count]
    }
}
