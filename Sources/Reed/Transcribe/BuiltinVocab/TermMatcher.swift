import Foundation

/// Literal, normalized, longest-match-first n-gram replacement over tokens.
///
/// No phonetics, no edit distance — deliberate (spec §2): a hidden curated
/// table must produce exactly the substitutions a human reviewed and nothing
/// else. The index is a first-token bucket map rather than a trie: ~300
/// entries with depth ≤6 make a trie's win unmeasurable, and a flat map is
/// auditable at a glance.
enum TermMatcher {
    struct Candidate {
        let entry: VocabEntry
        let domain: VocabDomain
        let rule: String   // "always" | "gated"
    }

    /// first normalized token → candidates, longest source first.
    static let buckets: [String: [Candidate]] = {
        var map: [String: [Candidate]] = [:]
        for (domain, entries) in VocabularyData.always {
            for entry in entries {
                map[entry.source[0], default: []]
                    .append(Candidate(entry: entry, domain: domain, rule: "always"))
            }
        }
        for (domain, entries) in VocabularyData.gated {
            for entry in entries {
                map[entry.source[0], default: []]
                    .append(Candidate(entry: entry, domain: domain, rule: "gated"))
            }
        }
        for key in map.keys {
            map[key]?.sort { $0.entry.source.count > $1.entry.source.count }
        }
        return map
    }()

    /// One pass, left to right, no re-entry: a replacement's output is never
    /// re-examined (spec §2 — prevents cascades). Tokens inside formatter
    /// claims are skipped entirely (locked spans).
    static func substitutions(tokens: [VocabToken], text: String,
                              active: Set<VocabDomain>,
                              claimed: Set<Int>) -> [CorrectionPass.Edit] {
        var edits: [CorrectionPass.Edit] = []
        var i = 0
        while i < tokens.count {
            guard !claimed.contains(i), let candidates = buckets[tokens[i].norm] else {
                i += 1
                continue
            }
            var advanced = false
            for candidate in candidates {
                let length = candidate.entry.source.count
                guard i + length <= tokens.count else { continue }
                // `always` and `gated` share the runtime rule — the domain
                // must be active (general always is). The split is a risk
                // classification carried into the audit record, and gated
                // sources are additionally barred from ever being anchors.
                guard candidate.domain == .general || active.contains(candidate.domain) else { continue }
                var matches = true
                // A sealed token ends the match ("the app. Store…" is not
                // App Store) — unless it's the entry's own last word.
                for offset in 0..<length
                where tokens[i + offset].norm != candidate.entry.source[offset]
                    || claimed.contains(i + offset)
                    || (offset < length - 1 && tokens[i + offset].sealed) {
                    matches = false
                    break
                }
                guard matches else { continue }
                let start = tokens[i].core.lowerBound
                let end = tokens[i + length - 1].core.upperBound
                // Capitalization-only entries: skip when already canonical,
                // which also makes the pass idempotent.
                if String(text[start..<end]) != candidate.entry.replacement {
                    edits.append(CorrectionPass.Edit(first: i, last: i + length - 1,
                                                     replacement: candidate.entry.replacement,
                                                     pattern: nil, domain: candidate.domain,
                                                     rule: candidate.rule))
                }
                i += length
                advanced = true
                break
            }
            if !advanced { i += 1 }
        }
        return edits
    }
}
