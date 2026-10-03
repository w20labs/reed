import Foundation

/// Dotted numbers — versions and addresses — split out of
/// SpokenFormatter+Numbers.swift (2026-10-02) to keep both files inside
/// swiftlint's 400-line cap. The rules here are shared by the labelled
/// `version` rule in SpokenFormatter.swift and the unlabelled `dottedNumber`
/// below, so both read a run exactly the same way.
extension SpokenFormatter {
    // MARK: - dotted numbers (versions, addresses)

    /// The separator words a version number may be dictated with. Only "dot"
    /// anchors an unlabelled dotted run (below): "point" is the decimal
    /// separator in prose ("one point five times"), so a bare "point" run is
    /// not assumed to be a version. Behind the word "version" either reads as
    /// a version, because the label already said so.
    static func isVersionSeparator(_ norm: String) -> Bool { norm == "point" || norm == "dot" }

    /// A single dictated digit: a ones word ("zero".."nine", "oh") or a digit
    /// token. Concatenating these is how a version or address read out digit
    /// by digit arrives ("one nine two" → 192, "0 five" → 05).
    private static func digitUnit(_ norm: String) -> String? {
        if digitToken(norm) != nil, !norm.contains(",") { return norm }
        if let unit = ones[norm] { return String(unit) }
        return nil
    }

    /// The maximal run of dictated digits at `i`, joined. Deliberately
    /// uncapped, unlike `digitConcat`: a seven-digit fraction is one whole
    /// component, not six digits and a leftover word.
    private static func digitRun(at i: Int, tokens: [VocabToken]) -> (String, Int)? {
        var units: [String] = [], idx = i
        while idx < tokens.count, let digit = digitUnit(tokens[idx].norm) { units.append(digit); idx += 1 }
        guard let first = units.first else { return nil }
        // Only single digits concatenate. Joining an already-grouped token
        // would merge two separate numbers ("250 1 dot 2" is not 2501.2);
        // stopping at the first leaves a numeric token behind, which
        // `dottedRun` then declines rather than render in part.
        guard units.count == 1 || units.allSatisfy({ $0.count == 1 }) else { return (first, 1) }
        return (units.joined(), units.count)
    }

    /// True when a token would begin another number. One of these left over
    /// after a component means the component was cut short, and a cut
    /// component must not be rendered (review 2026-10-02: "zero dot 0 five"
    /// rendered "0.0 five").
    private static func startsNumber(_ norm: String) -> Bool {
        digitUnit(norm) != nil || isNumberWord(norm)
            || ["hundred", "thousand", "million", "billion"].contains(norm)
    }

    /// One component of a dotted run, as text — never through `Int`, which
    /// drops a leading zero ("0 dot 03" is 0.03). Whichever reading consumes
    /// more of the numeric tokens wins, so a compound keeps its arithmetic
    /// ("one hundred twenty" → 120; review 2026-10-02: digit concatenation
    /// made it 10020) while a digit-by-digit run concatenates ("one nine two"
    /// → 192). On a tie the literal digits win, so leading zeros survive.
    static func dottedComponent(at i: Int, tokens: [VocabToken]) -> (String, Int)? {
        guard i < tokens.count else { return nil }
        let digits = digitRun(at: i, tokens: tokens)
        if let (value, used) = parseCardinal(at: i, tokens: tokens), used > (digits?.1 ?? 0) {
            return (String(value), used)
        }
        return digits
    }

    /// The components of a separator-joined numeric run at `i`, shared by the
    /// labelled `version` rule and the unlabelled `dottedNumber` below so both
    /// read a run the same way. Declined whole — never in part — when the run
    /// ends ON a separator ("zero dot three dot", however many components it
    /// already has) or when a component leaves a number word behind.
    static func dottedRun(at i: Int, tokens: [VocabToken],
                          separator: (String) -> Bool) -> (parts: [String], last: Int)? {
        guard i < tokens.count, !separator(tokens[i].norm),
              let (first, firstUsed) = dottedComponent(at: i, tokens: tokens) else { return nil }
        var parts = [first]
        var idx = i + firstUsed
        if idx < tokens.count, startsNumber(tokens[idx].norm) { return nil }
        while idx + 1 < tokens.count, separator(tokens[idx].norm),
              let (part, used) = dottedComponent(at: idx + 1, tokens: tokens) {
            parts.append(part); idx += 1 + used
            if idx < tokens.count, startsNumber(tokens[idx].norm) { return nil }
        }
        // One component is a plain number, not a dotted run — `cardinal` owns it.
        guard parts.count >= 2 else { return nil }
        if idx < tokens.count, separator(tokens[idx].norm) { return nil }
        return (parts, idx - 1)
    }

    /// A dotted numeric run — a version or an IP address: "zero dot three
    /// dot five" → 0.3.5, "ten dot zero dot zero dot one" → 10.0.0.1. Needs
    /// no label word, so it also fires mid-sentence ("we are running zero dot
    /// three dot five"). Emails and domains are claimed earlier in `claims()`,
    /// so "seven dot org" is never ours.
    static func dottedNumber(at i: Int, tokens: [VocabToken]) -> CorrectionPass.Edit? {
        // A run must start where a number starts. The scanner retries every
        // position, so after a run is declined it walks INTO it and would
        // convert the suffix ("one dot one nine two hundred dot three" →
        // "one dot one nine 200.3", review 2026-10-02); and a run touching
        // the other separator is the interior of a version expression
        // `version` already declined ("version one dot two point"). Either
        // way this position is mid-expression, not the start of one.
        if i > 0, startsNumber(tokens[i - 1].norm) || isVersionSeparator(tokens[i - 1].norm) {
            return nil
        }
        guard let run = dottedRun(at: i, tokens: tokens, separator: { $0 == "dot" }) else { return nil }
        if run.last + 1 < tokens.count, isVersionSeparator(tokens[run.last + 1].norm) { return nil }
        return CorrectionPass.Edit(first: i, last: run.last,
                                   replacement: run.parts.joined(separator: "."),
                                   pattern: "dotted_number", domain: nil, rule: nil)
    }
}
