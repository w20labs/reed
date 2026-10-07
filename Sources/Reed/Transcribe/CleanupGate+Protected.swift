import Foundation

/// The protected tokens (spec §6, 2026-08-19): what the vocabulary formatter
/// could have built must survive the model byte-identical, unless a licensed
/// correction or restart deleted it whole.
extension CleanupGate {
    /// Protected tokens gone from the proposal. An occurrence the proposal
    /// deleted whole, inside spans the gate licensed as a correction or a
    /// restart, is the abandoned option going, not a reformat: "at 7:00 PM.
    /// No, at 5:00 PM" may lose "7:00" (field 2026-10-06). Anything else
    /// gone, or kept only in part, still counts.
    static func unexcusedProtected(input: String, output: String, tokens: [GateVerdict.Token],
                                   deletions: [GateVerdict.Deletion]) -> [String] {
        // The classified window (an equivalent reading of the same edit), and
        // never one reaching the end: that is the wrong option kept.
        let excused = Set(deletions.filter {
            ($0.licence == .structural || $0.licence == .restart) && !$0.window.contains(tokens.count - 1)
        }.flatMap { Array($0.window) })
        return protectedRanges(input).compactMap { range in
            let token = String(input[range])
            guard !output.contains(token) else { return nil }
            let covering = tokens.indices.filter { tokens[$0].characters.overlaps(range) }
            return !covering.isEmpty && covering.allSatisfy(excused.contains) ? nil : token
        }
    }

    /// Whitespace tokens, edge quotes/sentence punctuation trimmed, that
    /// carry structure the model must not touch.
    static func protectedTokens(_ text: String) -> [String] {
        protectedRanges(text).map { String(text[$0]) }
    }

    /// Where each protected token sits in `text`, in order.
    static func protectedRanges(_ text: String) -> [Range<String.Index>] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            var token = Substring(raw)
            while let first = token.first, "\"'“”‘’(".contains(first) { token = token.dropFirst() }
            while let last = token.last, "\"'”’),.!?;:".contains(last) { token = token.dropLast() }
            guard token.count > 1 else { return nil }
            let hasDigit = token.contains(where: \.isNumber)
            let hasLetter = token.contains(where: \.isLetter)
            let structural = token.contains(".") || token.contains("/")
                || token.contains("@") || token.contains(":")
            guard structural || (hasDigit && hasLetter) else { return nil }
            return token.startIndex..<token.endIndex
        }
    }
}
