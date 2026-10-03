import Foundation

/// Span-level spoken-forms formatter (spec §4): runs BEFORE term correction,
/// universal except `legal_form_number`. Every produced span is locked —
/// term correction never touches it. Priority: email before domain (an email
/// contains a domain), currency/time before identifier (a bare digit run is
/// not an identifier).
enum SpokenFormatter {
    static let tlds: Set<String> = ["com", "org", "net", "edu", "gov", "io", "ai", "co",
                                    "dev", "app", "me", "us", "law", "uk", "ca", "de",
                                    "fr", "jp", "xyz", "so", "tv", "fm", "sh", "ly"]
    /// Prose words that end a leftward label/local-part walk. The email
    /// stop-list carries the 2026-08-15 field lesson: "we are at example.com"
    /// is a location statement, not an address.
    private static let walkStops: Set<String> = ["the", "a", "an", "of", "to", "at", "in",
        "on", "for", "and", "or", "my", "our", "your", "their", "his", "her", "its",
        "this", "that", "is", "was", "are", "were", "am", "be", "we", "you", "they",
        "me", "i", "it", "visit", "go", "check", "website", "site", "email", "dot",
        "slash", "live", "lives", "hosted", "available", "found", "up", "back",
        "meet", "arrive", "stay", "look", "working", "running", "deployed",
        // Audit 2026-08-25: "download it from example dot com" joined to
        // "fromexample.com"; "she works at acme.ai" to "she works@acme.ai".
        "from", "try", "use", "using", "download", "install", "works",
        "worked", "based", "contact", "reach", "see", "get", "via"]
    static let ones = ["zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4,
                               "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    static let teens = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
                                "fourteen": 14, "fifteen": 15, "sixteen": 16,
                                "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
                               "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    private static let identifierCues: Set<String> = ["number", "case", "id",
                                                      "reference", "confirmation"]

    static func claims(tokens: [VocabToken], text: String,
                       legalActive: Bool) -> [CorrectionPass.Edit] {
        var edits: [CorrectionPass.Edit] = []
        var claimed = Set<Int>()
        func claim(_ edit: CorrectionPass.Edit) {
            edits.append(edit)
            claimed.formUnion(edit.first...edit.last)
        }
        // Email and domain first, anchored at each spoken "dot".
        for dot in tokens.indices where tokens[dot].norm == "dot" && !claimed.contains(dot) {
            if let edit = emailOrDomain(at: dot, tokens: tokens, claimed: claimed) { claim(edit) }
        }
        // ASR often emits the domain already formed ("jane at example.com",
        // field 2026-08-19) — join those too, with the same prose guard.
        for pos in tokens.indices where tokens[pos].norm == "at" && !claimed.contains(pos) {
            if let edit = formedDomainEmail(at: pos, tokens: tokens, claimed: claimed) { claim(edit) }
        }
        var i = 0
        while i < tokens.count {
            if claimed.contains(i) { i += 1; continue }
            var found: CorrectionPass.Edit? = currency(at: i, tokens: tokens)
                ?? time(at: i, tokens: tokens)
                ?? phone(at: i, tokens: tokens)
                ?? version(at: i, tokens: tokens) ?? dottedNumber(at: i, tokens: tokens)
            if found == nil, legalActive { found = legalForm(at: i, tokens: tokens) }
            if found == nil { found = identifier(at: i, tokens: tokens) }
            // Inverse text normalization (cardinals, ordinals, clock times)
            // runs in `numberClaims`, after term matching — a vocabulary
            // spoken form ("eye ninety four" → I-94) outranks a bare number.
            if let found, !(found.first...found.last).contains(where: claimed.contains) {
                claim(found)
                i = found.last + 1
            } else {
                i += 1
            }
        }
        return edits
    }

    // MARK: - domain / email

    /// "jane at example.com" → jane@example.com. The domain token must
    /// already carry a listed TLD; the local part obeys the same prose
    /// stop-list, so "we are at example.com" stays a location statement.
    /// Also normalizes the domain's case ("Example.Com" → example.com).
    private static func formedDomainEmail(at pos: Int, tokens: [VocabToken],
                                          claimed: Set<Int>) -> CorrectionPass.Edit? {
        guard pos > 0, pos + 1 < tokens.count,
              !claimed.contains(pos - 1), !claimed.contains(pos + 1) else { return nil }
        let domain = tokens[pos + 1].norm
        let pieces = domain.split(separator: ".").map(String.init)
        guard pieces.count >= 2, let last = pieces.last, tlds.contains(last),
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } })
        else { return nil }
        let local = tokens[pos - 1].norm
        guard isLabelish(local) else { return nil }
        return CorrectionPass.Edit(first: pos - 1, last: pos + 1,
                                   replacement: "\(local)@\(domain)",
                                   pattern: "email", domain: nil, rule: nil)
    }

    private static func isLabelish(_ norm: String) -> Bool {
        guard !norm.isEmpty, !walkStops.contains(norm) else { return false }
        return norm.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Number words inside a label become digits ("w twenty labs" → w20labs).
    private static func labelPiece(_ norm: String) -> String {
        if let value = tens[norm] ?? teens[norm] { return String(value) }
        if let value = ones[norm], norm != "oh" { return String(value) }
        return norm
    }

    /// TLD at `i`: a listed token, or a run of spelled letters joining to one
    /// ("a i" → ai). Returns (tld, tokensConsumed).
    private static func tld(at i: Int, tokens: [VocabToken]) -> (String, Int)? {
        // A final "dot" sends idx + 1 past the end — crashed (review 2026-08-26).
        guard i < tokens.count else { return nil }
        if tlds.contains(tokens[i].norm) { return (tokens[i].norm, 1) }
        var joined = ""
        var idx = i
        while idx < tokens.count, tokens[idx].norm.count == 1,
              tokens[idx].norm.first?.isLetter == true {
            joined += tokens[idx].norm
            idx += 1
            if tlds.contains(joined) { return (joined, idx - i) }
            if joined.count >= 3 { break }
        }
        return nil
    }

    private static func emailOrDomain(at dot: Int, tokens: [VocabToken],
                                      claimed: Set<Int>) -> CorrectionPass.Edit? {
        // No TLD precheck here: in "docs dot example dot com" the token after
        // the FIRST dot is a label — the chain walk below validates the tail.
        guard dot > 0, dot + 1 < tokens.count else { return nil }
        // Left label: up to 4 labelish tokens.
        var start = dot
        while start > 0, dot - start < 4, isLabelish(tokens[start - 1].norm),
              !claimed.contains(start - 1) { start -= 1 }
        guard start < dot else { return nil }
        // Idiom guard (field 2026-08-15): an article within two tokens before
        // the name reads as a noun phrase — "a real dot com story".
        for back in 1...2 where start - back >= 0 {
            if ["a", "an", "the"].contains(tokens[start - back].norm) { return nil }
        }
        var parts = [tokens[start..<dot].map { labelPiece($0.norm) }.joined()]
        var idx = dot
        while idx < tokens.count, tokens[idx].norm == "dot" {
            if let (tldName, used) = tld(at: idx + 1, tokens: tokens) {
                // A tld token can still be an interior label ("docs dot co dot
                // uk") — terminal only if no further dot+label follows.
                let after = idx + 1 + used
                if after < tokens.count, tokens[after].norm == "dot" {
                    parts.append(tldName)
                    idx = after
                    continue
                }
                parts.append(tldName)
                idx = after
                break
            }
            guard idx + 1 < tokens.count, isLabelish(tokens[idx + 1].norm) else { return nil }
            parts.append(labelPiece(tokens[idx + 1].norm))
            idx += 2
        }
        guard let last = parts.last, tlds.contains(last) else { return nil }
        var replacement = parts.joined(separator: ".").lowercased()
        var end = idx - 1
        // Path: "slash" + word, repeatable.
        while end + 2 < tokens.count, tokens[end + 1].norm == "slash",
              isLabelish(tokens[end + 2].norm) {
            replacement += "/" + tokens[end + 2].norm
            end += 2
        }
        // Email: local part left of an "at", possibly with spoken dots. Every
        // token the walk consumes must be unclaimed — "example dot com at
        // gmail dot com" used to re-consume the already-claimed example.com
        // as a local part, and the two overlapping edits trapped in
        // CorrectionPass.apply (audit 2026-08-25).
        if start >= 2, tokens[start - 1].norm == "at",
           !claimed.contains(start - 1), !claimed.contains(start - 2) {
            var localStart = start - 2
            var local = [tokens[localStart].norm]
            if isLabelish(local[0]) {
                while localStart >= 2, tokens[localStart - 1].norm == "dot",
                      isLabelish(tokens[localStart - 2].norm),
                      !claimed.contains(localStart - 1),
                      !claimed.contains(localStart - 2) {
                    local.insert(tokens[localStart - 2].norm, at: 0)
                    localStart -= 2
                }
                return CorrectionPass.Edit(first: localStart, last: end,
                                           replacement: local.joined(separator: ".") + "@" + replacement,
                                           pattern: "email", domain: nil, rule: nil)
            }
        }
        return CorrectionPass.Edit(first: start, last: end, replacement: replacement,
                                   pattern: "domain_name", domain: nil, rule: nil)
    }

}

// MARK: - numbers, currency, time, phone, version, legal, identifier

extension SpokenFormatter {

    /// Compound integer: "two hundred fifty" → 250, "eighty five" → 85.
    static func parseInt(at i: Int, tokens: [VocabToken]) -> (Int, Int)? {
        // Callers pass computed indices (i + used) that can land past the end
        // — "version twenty five" crashed here (audit 2026-08-25).
        guard i < tokens.count else { return nil }
        var value = 0, idx = i, any = false
        // Recognizers mix shapes (field 2026-08-29: "3,100 and sixty-two
        // dollars"): a digit token, and a hyphenated compound, each count
        // as one number word.
        if let digits = digitToken(tokens[idx].norm) { return (digits, 1) }
        if let compound = hyphenated(tokens[idx].norm) { return (compound, 1) }
        if let tensValue = tens[tokens[idx].norm] {
            value = tensValue; idx += 1; any = true
            if idx < tokens.count, let unit = ones[tokens[idx].norm], unit > 0 { value += unit; idx += 1 }
        } else if let teenValue = teens[tokens[idx].norm] {
            value = teenValue; idx += 1; any = true
        } else if let unit = ones[tokens[idx].norm], tokens[idx].norm != "oh" {
            value = unit; idx += 1; any = true
        }
        guard any else { return nil }
        if idx < tokens.count, tokens[idx].norm == "hundred" {
            value *= 100; idx += 1
            if idx < tokens.count, let tensValue = tens[tokens[idx].norm] {
                value += tensValue; idx += 1
                if idx < tokens.count, let unit = ones[tokens[idx].norm], unit > 0 { value += unit; idx += 1 }
            } else if idx < tokens.count, let teenValue = teens[tokens[idx].norm] {
                value += teenValue; idx += 1
            } else if idx < tokens.count, let unit = ones[tokens[idx].norm], unit > 0 {
                value += unit; idx += 1
            }
        }
        return (value, idx - i)
    }

    /// "4,200" / "250" → 4200 / 250 (a plain digit token, grouping commas allowed).
    static func digitToken(_ norm: String) -> Int? {
        guard let first = norm.first, first.isNumber, norm.allSatisfy({ $0.isNumber || $0 == "," }) else { return nil }
        return Int(norm.replacingOccurrences(of: ",", with: ""))
    }

    /// "eighty-seven" → 87, "twenty-two" → 22.
    static func hyphenated(_ norm: String) -> Int? {
        let parts = norm.split(separator: "-").map(String.init)
        guard parts.count == 2, let tensValue = tens[parts[0]], let unit = ones[parts[1]], unit > 0 else { return nil }
        return tensValue + unit
    }

    /// Digit-string concatenation for forms/identifiers:
    /// "four eighty five" → "485", "one thirty" → "130", "oh five" → "05".
    static func digitConcat(at i: Int, tokens: [VocabToken], maxTokens: Int = 6) -> (String, Int)? {
        var s = "", idx = i
        while idx < tokens.count, idx - i < maxTokens {
            let norm = tokens[idx].norm
            if let tensValue = tens[norm] {
                if idx + 1 < tokens.count, let unit = ones[tokens[idx + 1].norm], unit > 0 {
                    s += String(tensValue + unit); idx += 2
                } else { s += String(tensValue); idx += 1 }
            } else if let teenValue = teens[norm] {
                s += String(teenValue); idx += 1
            } else if norm == "hundred", !s.isEmpty {
                s += "00"; idx += 1
            } else if let unit = ones[norm] {
                s += String(unit); idx += 1
            } else { break }
        }
        return s.isEmpty ? nil : (s, idx - i)
    }

    // MARK: - time, phone, version (currency lives in SpokenFormatter+Numbers)

    static func meridiem(at i: Int, tokens: [VocabToken]) -> (String, Int)? {
        let norm = tokens[i].norm
        if norm == "am" || norm == "a.m" { return ("AM", 1) }
        if norm == "pm" || norm == "p.m" { return ("PM", 1) }
        if i + 1 < tokens.count, tokens[i + 1].norm == "m" {
            if norm == "a" { return ("AM", 2) }
            if norm == "p" { return ("PM", 2) }
        }
        return nil
    }

    private static func time(at i: Int, tokens: [VocabToken]) -> CorrectionPass.Edit? {
        guard let (hour, used) = parseInt(at: i, tokens: tokens), (1...12).contains(hour)
        else { return nil }
        var idx = i + used
        var minute = -1
        if idx < tokens.count {
            if let tensValue = tens[tokens[idx].norm] {
                minute = tensValue; idx += 1
                if idx < tokens.count, let unit = ones[tokens[idx].norm], unit > 0 { minute += unit; idx += 1 }
            } else if let teenValue = teens[tokens[idx].norm] {
                minute = teenValue; idx += 1
            } else if tokens[idx].norm == "oh", idx + 1 < tokens.count,
                      let unit = ones[tokens[idx + 1].norm] {
                minute = unit; idx += 2
            }
        }
        guard minute < 60, idx < tokens.count,
              let (ampm, used) = meridiem(at: idx, tokens: tokens) else { return nil }
        let mm = minute < 0 ? "00" : String(format: "%02d", minute)
        return CorrectionPass.Edit(first: i, last: idx + used - 1,
                                   replacement: "\(hour):\(mm) \(ampm)",
                                   pattern: "time", domain: nil, rule: nil)
    }

    private static func phone(at i: Int, tokens: [VocabToken]) -> CorrectionPass.Edit? {
        var digits = ""
        var idx = i
        while idx < tokens.count, digits.count < 10,
              let digit = ones[tokens[idx].norm], tokens[idx].norm != "oh" || !digits.isEmpty {
            digits += String(digit); idx += 1
        }
        guard digits.count == 10 else { return nil }
        let area = digits.prefix(3), mid = digits.dropFirst(3).prefix(3), tail = digits.suffix(4)
        return CorrectionPass.Edit(first: i, last: idx - 1, replacement: "(\(area)) \(mid)-\(tail)",
                                   pattern: "phone_us", domain: nil, rule: nil)
    }

    /// "version two point three point one" / "version zero dot three dot
    /// five" → v2.3.1 / v0.3.5. The run itself is parsed by `dottedRun`, so
    /// a labelled version reads components exactly as an unlabelled dotted
    /// run does: leading zeros kept, digit-by-digit spelling joined, and an
    /// unfinished run left spoken.
    private static func version(at i: Int, tokens: [VocabToken]) -> CorrectionPass.Edit? {
        guard tokens[i].norm == "version",
              let run = dottedRun(at: i + 1, tokens: tokens, separator: isVersionSeparator)
        else { return nil }
        return CorrectionPass.Edit(first: i, last: run.last,
                                   replacement: "v" + run.parts.joined(separator: "."),
                                   pattern: "version", domain: nil, rule: nil)
    }

    // MARK: - legal form numbers (gated on an active legal domain)

    private static func legalForm(at i: Int, tokens: [VocabToken]) -> CorrectionPass.Edit? {
        guard tokens[i].norm == "form", i + 2 < tokens.count else { return nil }
        var letters = ""
        var idx = i + 1
        while idx < tokens.count, letters.count < 2, tokens[idx].norm.count == 1,
              tokens[idx].norm.first!.isLetter { letters += tokens[idx].norm.uppercased(); idx += 1 }
        guard !letters.isEmpty, let (digits, used) = digitConcat(at: idx, tokens: tokens)
        else { return nil }
        idx += used
        var suffix = ""
        if idx < tokens.count, tokens[idx].norm.count == 1, tokens[idx].norm.first!.isLetter {
            suffix = tokens[idx].norm.uppercased(); idx += 1
        }
        return CorrectionPass.Edit(first: i, last: idx - 1,
                                   replacement: "Form \(letters)-\(digits)\(suffix)",
                                   pattern: "legal_form_number", domain: nil, rule: nil)
    }

    // MARK: - identifier (highest false-positive risk; gated hard)

    /// Stricter than spec, per its own instruction: requires a preceding cue
    /// word AND ≥2 spelled letters AND ≥1 digit AND ≥6 characters total.
    private static func identifier(at i: Int, tokens: [VocabToken]) -> CorrectionPass.Edit? {
        guard identifierCues.contains(tokens[i].norm), i + 3 < tokens.count else { return nil }
        var letters = ""
        var idx = i + 1
        while idx < tokens.count, tokens[idx].norm.count == 1, tokens[idx].norm.first!.isLetter {
            letters += tokens[idx].norm.uppercased(); idx += 1
        }
        guard letters.count >= 2, let (digits, used) = digitConcat(at: idx, tokens: tokens)
        else { return nil }
        let value = letters + digits
        guard value.count >= 6 else { return nil }
        return CorrectionPass.Edit(first: i + 1, last: idx + used - 1, replacement: value,
                                   pattern: "identifier", domain: nil, rule: nil)
    }
}
