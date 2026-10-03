import Foundation

/// Inverse text normalization for prose numbers (finding 3, 2026-08-29,
/// docs/bench/itn_before.txt): Parakeet spells out what Whisper wrote as
/// digits — "two hundred and fifty participants", "the fifteenth of March",
/// "half past four" — and varies take to take. These rules make the
/// rendering deterministic whatever the recognizer emitted. Style (the
/// user's call): one–nine stay words in prose, ten and up are digits; a
/// number after a label word ("phase two", "room four") is a digit; ordinals
/// are digits only in dates; clock times are H:MM.
extension SpokenFormatter {
    static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30
    ]
    static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july",
                                      "august", "september", "october", "november", "december"]
    static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday",
                                        "saturday", "sunday"]
    /// A count after one of these is a label, written as a digit even under ten.
    static let countLabels: Set<String> = [
        "phase", "step", "chapter", "room", "extension", "part", "page", "item", "level", "gate",
        "line", "unit", "week", "day", "quarter", "sprint", "round", "season", "episode", "table",
        "figure", "section", "stage", "floor", "grade", "zone", "lane", "track", "slide", "tier",
        "group", "team", "option", "number", "version", "build", "iteration"
    ]
    /// Words that put a following "H M" in the clock ("at nine thirty").
    static let timeCues: Set<String> = ["at", "around", "by", "until", "till", "before", "after", "about"]

    /// `meridiem` indexes without a bounds check; every call here can land
    /// past the end of the token list.
    private static func meridiemSafe(at i: Int, tokens: [VocabToken]) -> (String, Int)? {
        guard i < tokens.count else { return nil }
        return meridiem(at: i, tokens: tokens)
    }

    /// The ITN rules over every token nobody claimed yet — formatter spans
    /// and vocabulary substitutions both take precedence.
    static func numberClaims(tokens: [VocabToken], claimed: Set<Int>) -> [CorrectionPass.Edit] {
        var edits: [CorrectionPass.Edit] = []
        var taken = claimed
        var i = 0
        while i < tokens.count {
            if taken.contains(i) { i += 1; continue }
            var found = clockTime(at: i, tokens: tokens)
            if found == nil { found = ordinalDate(at: i, tokens: tokens) }
            if found == nil { found = cardinal(at: i, tokens: tokens) }
            if let found, !(found.first...found.last).contains(where: taken.contains) {
                edits.append(found)
                taken.formUnion(found.first...found.last)
                i = found.last + 1
            } else {
                i += 1
            }
        }
        return edits
    }

    // MARK: - currency

    /// "three thousand one hundred and sixty two dollars" → $3,162;
    /// "one point two million dollars" → $1.2 million; "five dollars" → $5.
    static func currency(at i: Int, tokens: [VocabToken]) -> CorrectionPass.Edit? {
        guard let (intVal, used) = parseInt(at: i, tokens: tokens) else { return nil }
        var idx = i + used
        var amount = String(intVal)
        if idx + 1 < tokens.count, tokens[idx].norm == "point",
           let firstDecimal = ones[tokens[idx + 1].norm] {
            amount += ".\(firstDecimal)"; idx += 2
            while idx < tokens.count, let digit = ones[tokens[idx].norm] {
                amount += String(digit); idx += 1
            }
        }
        var scale = ""
        if idx < tokens.count, ["thousand", "million", "billion"].contains(tokens[idx].norm) {
            scale = " " + tokens[idx].norm; idx += 1
        }
        if idx < tokens.count, ["dollars", "dollar"].contains(tokens[idx].norm) {
            return CorrectionPass.Edit(first: i, last: idx, replacement: "$\(amount)\(scale)",
                                       pattern: "currency", domain: nil, rule: nil)
        }
        // The compound form: thousands, hundreds and "and" before "dollars".
        if let (whole, wholeUsed) = parseCardinal(at: i, tokens: tokens), wholeUsed > used,
           i + wholeUsed < tokens.count, ["dollars", "dollar"].contains(tokens[i + wholeUsed].norm) {
            return CorrectionPass.Edit(first: i, last: i + wholeUsed, replacement: "$" + grouped(whole),
                                       pattern: "currency", domain: nil, rule: nil)
        }
        return nil
    }

    // MARK: - cardinals

    /// "two hundred and fifty" → 250; "three thousand one hundred and sixty
    /// two" → 3162. Accepts "and" after hundreds and scale words.
    static func parseCardinal(at i: Int, tokens: [VocabToken]) -> (value: Int, used: Int)? {
        var idx = i
        var total = 0
        var any = false
        for (scale, word) in [(1_000_000, "million"), (1_000, "thousand")] {
            if let (group, used) = parseGroup(at: idx, tokens: tokens),
               idx + used < tokens.count, tokens[idx + used].norm == word {
                total += group * scale; idx += used + 1; any = true
                if idx < tokens.count, tokens[idx].norm == "and",
                   idx + 1 < tokens.count, parseGroup(at: idx + 1, tokens: tokens) != nil { idx += 1 }
            }
        }
        if let (group, used) = parseGroup(at: idx, tokens: tokens) {
            total += group; idx += used; any = true
        }
        return any ? (total, idx - i) : nil
    }

    /// 0–999 with an optional "and" after the hundreds.
    private static func parseGroup(at i: Int, tokens: [VocabToken]) -> (Int, Int)? {
        guard let (value, used) = parseInt(at: i, tokens: tokens) else { return nil }
        var idx = i + used
        var total = value
        let roundHundreds = (used >= 2 && tokens[i + used - 1].norm == "hundred") || (total >= 100 && total % 100 == 0)
        if roundHundreds, idx < tokens.count, tokens[idx].norm == "and",
           idx + 1 < tokens.count, let (rest, restUsed) = parseInt(at: idx + 1, tokens: tokens), rest < 100 {
            total += rest; idx += 1 + restUsed
        }
        return (total, idx - i)
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// A letter, or a spoken letter name that is not also an everyday word
    /// ("eye ninety four" is I-94, a vocabulary form; "are twenty" is prose).
    private static let letterNames: Set<String> = ["eye", "bee", "dee", "gee", "jay", "kay", "el", "em",
                                                   "en", "ex", "tee", "vee", "zed", "zee", "ess", "aitch",
                                                   "eff", "pee", "cue", "que"]
    private static func isLoneLetter(_ norm: String) -> Bool {
        (norm.count == 1 && norm.first!.isLetter) || letterNames.contains(norm)
    }

    static func isNumberWord(_ norm: String) -> Bool {
        ones[norm] != nil || teens[norm] != nil || tens[norm] != nil || hyphenated(norm) != nil
    }

    static func cardinal(at i: Int, tokens: [VocabToken]) -> CorrectionPass.Edit? {
        // A hyphenated compound is a number word; a bare digit token is not
        // ours to rewrite (it is already a digit) unless a spoken tail
        // follows it ("3,100 and sixty-two").
        let norm = tokens[i].norm
        let startsSpoken = isNumberWord(norm) || hyphenated(norm) != nil
        let digitsThenSpoken = digitToken(norm) != nil && i + 2 < tokens.count && tokens[i + 1].norm == "and"
            && (isNumberWord(tokens[i + 2].norm) || hyphenated(tokens[i + 2].norm) != nil)
        guard startsSpoken || digitsThenSpoken, norm != "oh" else { return nil }
        let labelled = i > 0 && countLabels.contains(tokens[i - 1].norm)
        // After a label word the run is a digit string: "room four oh two"
        // → 402, "extension one one nine" → 119, "phase two" → 2.
        if labelled, let (digits, used) = digitConcat(at: i, tokens: tokens) {
            // A dangling separator is an unfinished version number — leave it spoken.
            if i + used < tokens.count, isVersionSeparator(tokens[i + used].norm) { return nil }
            return CorrectionPass.Edit(first: i, last: i + used - 1, replacement: digits,
                                       pattern: "cardinal", domain: nil, rule: nil)
        }
        guard let (value, used) = parseCardinal(at: i, tokens: tokens) else { return nil }
        let next = i + used < tokens.count ? tokens[i + used].norm : ""
        // Other rules own these continuations.
        // "dot" alongside "point": a number before either separator belongs to
        // a version run, so it stays spoken when that run was declined as
        // unfinished ("ten dot zero dot zero dot").
        if ["o'clock", "o’clock", "dollars", "dollar", "point", "dot", "thousand", "million", "billion"].contains(next) { return nil }
        if meridiemSafe(at: i + used, tokens: tokens) != nil { return nil }
        // A number word beside another number word is a run — a price, a
        // time, an identifier — that the rules above declined; it stays
        // spoken ("ten ninety nine", "three thirty").
        if isNumberWord(next) || (i > 0 && isNumberWord(tokens[i - 1].norm)) { return nil }
        // Beside a lone letter it is an identifier ("eighty three b", "n four
        // hundred", "form i four eighty five") — the legal-form rule's, when active.
        let prev = i > 0 ? tokens[i - 1].norm : ""
        if isLoneLetter(prev) || isLoneLetter(next) { return nil }
        let percent = next == "percent"
        guard percent || value >= 10 else { return nil }
        let last = i + used - (percent ? 0 : 1)
        return CorrectionPass.Edit(first: i, last: last,
                                   replacement: grouped(value) + (percent ? "%" : ""),
                                   pattern: percent ? "percent" : "cardinal", domain: nil, rule: nil)
    }

    // MARK: - ordinals in dates

    static func ordinalDate(at i: Int, tokens: [VocabToken]) -> CorrectionPass.Edit? {
        guard let (value, used) = parseOrdinal(at: i, tokens: tokens) else { return nil }
        let prev = i > 0 ? tokens[i - 1].norm : ""
        let prev2 = i > 1 ? tokens[i - 2].norm : ""
        let next = i + used < tokens.count ? tokens[i + used].norm : ""
        let next2 = i + used + 1 < tokens.count ? tokens[i + used + 1].norm : ""
        // "<ordinal> of <month>" is a date whatever precedes it (field
        // 2026-08-29: "due on fifteenth of march", no "the").
        let inDate = months.contains(prev)
            || (prev == "the" && (weekdays.contains(prev2) || months.contains(prev2) || prev2 == "on"))
            || (next == "of" && months.contains(next2))
        guard inDate else { return nil }
        // Parakeet lowercases month names ("the fifteenth of march"): a
        // month inside the date span comes out capitalized.
        if next == "of", months.contains(next2) {
            return CorrectionPass.Edit(first: i, last: i + used + 1,
                                       replacement: "\(ordinalString(value)) of \(next2.capitalized)",
                                       pattern: "ordinal", domain: nil, rule: nil)
        }
        return CorrectionPass.Edit(first: i, last: i + used - 1, replacement: ordinalString(value),
                                   pattern: "ordinal", domain: nil, rule: nil)
    }

    private static func parseOrdinal(at i: Int, tokens: [VocabToken]) -> (Int, Int)? {
        if let value = ordinalWords[tokens[i].norm] { return (value, 1) }
        if let tensValue = tens[tokens[i].norm], i + 1 < tokens.count,
           let unit = ordinalWords[tokens[i + 1].norm], unit < 10 { return (tensValue + unit, 2) }
        return nil
    }

    static func ordinalString(_ value: Int) -> String {
        let suffix: String
        switch value % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(value)\(suffix)"
    }

    // MARK: - clock times

    /// Hour 1–12 as a word or a digit token.
    private static func parseHour(at i: Int, tokens: [VocabToken]) -> (Int, Int)? {
        guard i < tokens.count else { return nil }
        if let digits = Int(tokens[i].norm), (1...12).contains(digits) { return (digits, 1) }
        if let (value, used) = parseInt(at: i, tokens: tokens), (1...12).contains(value) { return (value, used) }
        return nil
    }

    /// Minutes 0–59 as a word run or a digit token.
    private static func parseMinutes(at i: Int, tokens: [VocabToken]) -> (Int, Int)? {
        guard i < tokens.count else { return nil }
        if tokens[i].norm.count == 2, let digits = Int(tokens[i].norm), (0...59).contains(digits) { return (digits, 1) }
        if let tensValue = tens[tokens[i].norm], tensValue < 60 {
            if i + 1 < tokens.count, let unit = ones[tokens[i + 1].norm], unit > 0 { return (tensValue + unit, 2) }
            return (tensValue, 1)
        }
        if let teenValue = teens[tokens[i].norm] { return (teenValue, 1) }
        if tokens[i].norm == "oh", i + 1 < tokens.count, let unit = ones[tokens[i + 1].norm] { return (unit, 2) }
        return nil
    }

    private static func clock(_ hour: Int, _ minute: Int, at i: Int, last: Int, tokens: [VocabToken]) -> CorrectionPass.Edit {
        var end = last
        var text = String(format: "%d:%02d", hour, minute)
        if let (ampm, used) = meridiemSafe(at: last + 1, tokens: tokens) { text += " " + ampm; end = last + used }
        return CorrectionPass.Edit(first: i, last: end, replacement: text, pattern: "clock", domain: nil, rule: nil)
    }

    static func clockTime(at i: Int, tokens: [VocabToken]) -> CorrectionPass.Edit? {
        let norm = tokens[i].norm
        // "half past four", "quarter past four", "quarter to five"
        if norm == "half" || norm == "quarter", i + 2 < tokens.count,
           ["past", "to"].contains(tokens[i + 1].norm),
           let (hour, used) = parseHour(at: i + 2, tokens: tokens) {
            let last = i + 1 + used
            if tokens[i + 1].norm == "past" {
                return clock(hour, norm == "half" ? 30 : 15, at: i, last: last, tokens: tokens)
            }
            if norm == "quarter" {
                return clock(hour == 1 ? 12 : hour - 1, 45, at: i, last: last, tokens: tokens)
            }
            return nil
        }
        // "11.45 pm", "9.30 in the morning" (a recognizer's dot for a colon)
        if let dot = norm.firstIndex(of: "."), let hour = Int(norm[..<dot]), (1...12).contains(hour),
           norm[norm.index(after: dot)...].count == 2, let minute = Int(norm[norm.index(after: dot)...]), minute < 60,
           meridiemSafe(at: i + 1, tokens: tokens) != nil || (i > 0 && timeCues.contains(tokens[i - 1].norm)) {
            return clock(hour, minute, at: i, last: i, tokens: tokens)
        }
        guard let (hour, hourUsed) = parseHour(at: i, tokens: tokens) else { return nil }
        let after = i + hourUsed
        // "three o'clock" → "3 o'clock" (a digit hour is already fine)
        if after < tokens.count, ["o'clock", "o’clock"].contains(tokens[after].norm), Int(norm) == nil {
            return CorrectionPass.Edit(first: i, last: after, replacement: "\(hour) o'clock",
                                       pattern: "clock", domain: nil, rule: nil)
        }
        // "nine thirty" / "9 30" — only under a time cue or a meridiem; the
        // spoken "nine thirty am" form is the existing `time` rule's.
        if let (minute, minUsed) = parseMinutes(at: after, tokens: tokens), minute >= 10 || tokens[after].norm == "oh" {
            let last = after + minUsed - 1
            let cued = i > 0 && timeCues.contains(tokens[i - 1].norm)
            let hasMeridiem = meridiemSafe(at: last + 1, tokens: tokens) != nil
            let anyWord = Int(norm) == nil || Int(tokens[after].norm) == nil
            guard hasMeridiem || (cued && (anyWord || tokens[after].norm.count == 2)) else { return nil }
            return clock(hour, minute, at: i, last: last, tokens: tokens)
        }
        return nil
    }
}
