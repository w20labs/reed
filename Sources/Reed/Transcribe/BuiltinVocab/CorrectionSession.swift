import Foundation

/// Per-session domain activation (spec §3). A segment is one dictation; the
/// session lives for the app run, entirely in memory — nothing persists, and
/// nothing about domain state ever touches disk.
///
/// Deviations from the spec as written, both approved 2026-08-19:
/// - Activation needs ≥2 DISTINCT anchors with ≥1 STRONG in the window. The
///   flat "2 hits" rule activated estate off the modal "will" for everyone.
/// - Deactivation uses a per-domain quiet counter (≥15 segments since the
///   last hit) — a 5-segment window cannot observe 15 quiet segments.
final class CorrectionSession {
    static let windowSegments = 5
    static let activationDistinctAnchors = 2
    static let deactivationQuietSegments = 15

    /// One anchor term hit, tagged by strength.
    private struct Hit: Hashable {
        let term: String
        let strong: Bool
    }

    private var window: [[VocabDomain: Set<Hit>]] = []
    private var quiet: [VocabDomain: Int] = [:]
    private(set) var active: Set<VocabDomain> = [.general]

    private struct Anchor {
        let tokens: [String]
        let strong: Bool
        let term: String
    }

    /// Anchor n-grams per domain: the explicit strong/weak lists plus every
    /// canonical value the domain's `always` map produces (spec §3 — those
    /// bootstrap activation). Canonicals count as strong: they are
    /// domain-specific jargon by construction.
    private static let anchorIndex: [VocabDomain: [Anchor]] = {
        var map: [VocabDomain: [Anchor]] = [:]
        for domain in VocabDomain.allCases where domain != .general {
            var list: [Anchor] = []
            for anchor in VocabularyData.anchorsStrong[domain] ?? [] {
                list.append(Anchor(tokens: anchor.split(separator: " ").map(String.init),
                                   strong: true, term: anchor))
            }
            for anchor in VocabularyData.anchorsWeak[domain] ?? [] {
                list.append(Anchor(tokens: anchor.split(separator: " ").map(String.init),
                                   strong: false, term: anchor))
            }
            for entry in VocabularyData.always[domain] ?? [] {
                let canonical = entry.replacement.lowercased()
                list.append(Anchor(tokens: canonical.split(separator: " ").map(String.init),
                                   strong: true, term: canonical))
            }
            map[domain] = list
        }
        return map
    }()

    /// Apply the pass with the CURRENT active set, then recompute activation
    /// from the corrected text (spec §3 ordering: `always` substitutions
    /// produce the canonical anchors that bootstrap their own domain).
    func apply(_ text: String) -> CorrectionResult {
        let result = CorrectionPass.apply(text, active: active)
        observe(result.text)
        return CorrectionResult(text: result.text,
                                substitutions: result.substitutions,
                                formattedSpans: result.formattedSpans,
                                activeDomains: active)
    }

    private func observe(_ correctedText: String) {
        let norms = CorrectionPass.tokenize(correctedText).map(\.norm)
        var segment: [VocabDomain: Set<Hit>] = [:]
        for (domain, anchors) in Self.anchorIndex {
            var hits = Set<Hit>()
            for anchor in anchors where contains(norms, anchor.tokens) {
                hits.insert(Hit(term: anchor.term, strong: anchor.strong))
            }
            if !hits.isEmpty { segment[domain] = hits }
        }
        window.append(segment)
        if window.count > Self.windowSegments { window.removeFirst() }

        for domain in VocabDomain.allCases where domain != .general {
            if segment[domain] != nil {
                quiet[domain] = 0
            } else {
                quiet[domain, default: 0] += 1
            }
            let inWindow = window.compactMap { $0[domain] }.reduce(into: Set<Hit>()) { $0.formUnion($1) }
            // "Distinct" means independent evidence (audit 2026-08-25): an
            // anchor phrase that CONTAINS another ("irrevocable trust" ⊃
            // "trust") is one hit, not two — without this, a single sentence
            // activated the domain and unlocked its gated rewrites.
            let distinct = inWindow.filter { hit in
                let tokens = hit.term.split(separator: " ").map(String.init)
                return !inWindow.contains { other in
                    other.term != hit.term
                        && other.term.split(separator: " ").count > tokens.count
                        && contains(other.term.split(separator: " ").map(String.init), tokens)
                }
            }
            if distinct.count >= Self.activationDistinctAnchors,
               distinct.contains(where: \.strong) {
                active.insert(domain)
            }
            if active.contains(domain), quiet[domain, default: 0] >= Self.deactivationQuietSegments {
                active.remove(domain)
            }
        }
    }

    private func contains(_ norms: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, norms.count >= needle.count else { return false }
        for i in 0...(norms.count - needle.count)
        where Array(norms[i..<i + needle.count]) == needle { return true }
        return false
    }
}
