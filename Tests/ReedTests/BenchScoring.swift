import Foundation

/// Scoring shared by the gated benches, pinned to the analyzer scripts'
/// arithmetic (scripts/analyze_p1.py, scripts/asr_wer.py, scripts/qa) so a
/// bench and the QA page can never disagree at a ceiling (review 2026-09-01:
/// nearest-rank in Swift vs linear interpolation in Python passed and failed
/// the same 100-sample run).
enum BenchScoring {
    /// Linear-interpolation percentile — numpy's default and the scripts'
    /// `pct`. Nil for no samples: a ceiling must never be judged on nothing.
    static func percentile(_ values: [Int], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted().map(Double.init)
        let k = Double(sorted.count - 1) * q
        let lower = Int(k)
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (k - Double(lower))
    }

    /// asr_wer.py `norm`: lowercase, curly apostrophe straightened, every
    /// run of anything but [a-z0-9' ] becomes a space, split on whitespace.
    static func normalize(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        var out = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars {
            let keep = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "'" || scalar == " "
            out.append(keep ? scalar : " ")
        }
        return String(out).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// Word-level Levenshtein distance between a reference and a hypothesis.
    static func editDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
        guard !reference.isEmpty else { return hypothesis.count }
        var row = Array(0...hypothesis.count)
        for i in 1...reference.count {
            var diagonal = row[0]
            row[0] = i
            if hypothesis.isEmpty { continue }
            for j in 1...hypothesis.count {
                let above = row[j]
                let substitution = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
                row[j] = min(row[j] + 1, row[j - 1] + 1, diagonal + substitution)
                diagonal = above
            }
        }
        return row[hypothesis.count]
    }

    /// Either rendering of a number is right ("$3,162" and "three thousand one
    /// hundred sixty two" are the same words spoken): score against every
    /// reference and keep the lowest rate, the first one on a tie — exactly
    /// asr_wer.py `best` with [verbatim, clean].
    static func bestErrors(hypothesis: String, references: [String]) -> (errors: Int, words: Int) {
        let hyp = normalize(hypothesis)
        var best: (errors: Int, words: Int)?
        for reference in references {
            let ref = normalize(reference)
            let errors = editDistance(ref, hyp)
            let rate = Double(errors) / Double(max(ref.count, 1))
            if let current = best, Double(current.errors) / Double(max(current.words, 1)) <= rate { continue }
            best = (errors, ref.count)
        }
        return best ?? (0, 0)
    }
}
