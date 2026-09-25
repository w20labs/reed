import Foundation

/// A pause seam read from the audio on both sides of the seal (seam
/// experiment, 2026-09-10). Assembly decides a pause seam from text
/// alone: each half was recognized and cleaned as its own utterance, so
/// the recognizer closed the head with a period whether or not the
/// sentence went on (SeamRules, decision 1), and the on-device model
/// judge measured at chance. The recognizer punctuates a phrase it hears
/// whole, so this reads a short window across the seal and takes the mark
/// it wrote between the head's last word and the next's first. A reading
/// that cannot find both words adjacent in the window decides nothing,
/// and the seam stays exactly as before.
///
/// Flag `cleanup_seam_reading`, default OFF. `SeamReadingBenchTests`
/// measures it on live seal points against human-reviewed punctuation;
/// it ships only if corrected seams exceed broken ones with every word
/// preserved and the added latency acceptable (agreed 2026-09-10).
enum SeamReading {
    static let flag = "cleanup_seam_reading"
    static let flagDefault = false
    /// Audio on each side of the seal.
    static let halfWindowMs = 2_000
    /// Less than this on a side is not a reading.
    static let minSideMs = 300
    static let bytesPerMs = 32
    /// How many words of context on each side are aligned to the window.
    static let contextWords = 3
    /// A pause seals at the START of the silence, so the next words may
    /// begin seconds after the seal: the after-side skips leading silence
    /// (scanned this far, 20 ms frames, speech = within 20 dB of the scan's
    /// peak and above −55 dBFS) before it counts its two seconds.
    static let maxLeadMs = 4_000
    static let frameMs = 20
    /// Filler sounds the halves were cleaned of but the window still hears;
    /// a mark on one moves to the word before it.
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "mm", "hmm", "ah"]

    /// Why a reading decided nothing — content-free, for the bench's tally.
    enum Undecided: String, Equatable, CaseIterable {
        case emptyWindow, headWordMissing, nextWordMissing, notAdjacent, nameAfterNothing, breathRule, questionKept
    }

    enum Verdict: Equatable {
        case mark(SeamMark)
        case undecided(Undecided)
    }

    /// Test seam: sees every window's raw PCM before denoise, so a test can
    /// check the bytes cut without depending on the shared denoiser's state.
    nonisolated(unsafe) static var windowObserverForTests: ((Data) -> Void)?

    /// The PCM across the seal: `halfWindowMs` before it, and after it the
    /// leading silence plus `halfWindowMs`, clamped to the head's start and
    /// the next's end. Nil when a side holds less than `minSideMs` of audio
    /// (of speech, on the next side).
    static func window(pcm: Data, seal: Int, headStart: Int, nextEnd: Int) -> Data? {
        let half = halfWindowMs * bytesPerMs, minSide = minSideMs * bytesPerMs
        guard seal >= 0, seal <= pcm.count else { return nil }
        let nextEnd = min(nextEnd, pcm.count)
        // Both ends land on the quietest frame nearby: a cut inside a word
        // provokes the recognizer's slice-start collapse and its invented
        // phrase completions (LongAudioChunker, SecondReading).
        let start = quietestFrame(pcm: pcm, in: max(headStart, seal - half - cutSearch)..<max(headStart, seal - half + cutSearch))
        // No speech within the scan: a pause that long is left as it is.
        guard let lead = leadingSilence(pcm: pcm, from: seal, to: nextEnd, speechAt: start..<seal) else { return nil }
        let wanted = min(nextEnd, seal + lead + half)
        let end = wanted == nextEnd ? nextEnd : quietestFrame(pcm: pcm, in: max(seal + lead, wanted - cutSearch)..<min(nextEnd, wanted + cutSearch))
        guard start >= 0, seal - start >= minSide, end - (seal + lead) >= minSide else { return nil }
        return pcm.subdata(in: start..<end)
    }

    /// How far around a wanted cut the quietest frame is looked for.
    static let cutSearch = 400 * bytesPerMs

    /// Bytes of silence at the start of the next side; nil when nothing
    /// within `maxLeadMs` is as loud as the speech before the seal, less
    /// `speechDropDB`. The floor is the HEAD's level: a side of room noise
    /// judged against its own peak would read as speech from its first frame.
    static func leadingSilence(pcm: Data, from: Int, to: Int, speechAt head: Range<Int>) -> Int? {
        let frame = frameMs * bytesPerMs
        let scanEnd = min(to, from + maxLeadMs * bytesPerMs)
        guard let headPeak = frameLevels(pcm: pcm, in: head).max() else { return nil }
        let threshold = max(headPeak - speechDropDB, silenceFloorDB)
        let levels = frameLevels(pcm: pcm, in: from..<scanEnd)
        guard let first = firstSpeechRun(levels.map { $0 > threshold }) else { return nil }
        return first * frame
    }

    /// The first frame of the first run of speech at least `minRunFrames`
    /// long (gaps of up to `maxGapFrames` inside a run tolerated): a lone
    /// "um" right after the seal is a blip, not the next words.
    static func firstSpeechRun(_ speech: [Bool]) -> Int? {
        var runStart: Int?
        var gap = 0
        for (index, isSpeech) in speech.enumerated() {
            if isSpeech {
                if runStart == nil { runStart = index }
                gap = 0
                if let start = runStart, index - start + 1 >= minRunFrames { return start }
            } else if runStart != nil {
                gap += 1
                if gap > maxGapFrames { runStart = nil; gap = 0 }
            }
        }
        return nil
    }

    static let minRunFrames = 15   // 300 ms
    static let maxGapFrames = 5    // 100 ms

    static let speechDropDB = 20.0
    static let silenceFloorDB = -55.0

    /// The start of the quietest `frameMs` frame in `range` (its start when the range is shorter than a frame).
    static func quietestFrame(pcm: Data, in range: Range<Int>) -> Int {
        let frame = frameMs * bytesPerMs
        let levels = frameLevels(pcm: pcm, in: range)
        guard let quietest = levels.indices.min(by: { levels[$0] < levels[$1] }) else { return range.lowerBound }
        return range.lowerBound + quietest * frame
    }

    /// dBFS per `frameMs` frame across `range`.
    static func frameLevels(pcm: Data, in range: Range<Int>) -> [Double] {
        let frame = frameMs * bytesPerMs
        var levels: [Double] = []
        var at = max(0, range.lowerBound)
        while at + frame <= min(range.upperBound, pcm.count) {
            levels.append(LongAudioChunker.rmsDB(pcm.subdata(in: at..<(at + frame))))
            at += frame
        }
        return levels
    }

    /// What the window's text says the seam is: the mark on the token
    /// aligned to the head's last word, provided the next's first word is
    /// the token right after it. `head` and `next` are the halves as
    /// assembly holds them; only their words matter here.
    static func decide(head: String, next: String, window: String) -> Verdict {
        let tokens = spokenTokens(window)
        guard !tokens.isEmpty else { return .undecided(.emptyWindow) }
        let windowWords = tokens.map { words($0).joined() }
        let headTail = Array(words(head).suffix(contextWords)), nextHead = Array(words(next).prefix(contextWords))
        guard !headTail.isEmpty else { return .undecided(.headWordMissing) }
        guard !nextHead.isEmpty else { return .undecided(.nextWordMissing) }
        let aligned = alignment(headTail + nextHead, windowWords)
        guard let at = aligned[headTail.count - 1] else { return .undecided(.headWordMissing) }
        // The token right after the head's last word must be one of the
        // next's first words: the mark between them is the seam's even when
        // the window dropped the very first one.
        let nextPositions = (0..<nextHead.count).compactMap { aligned[headTail.count + $0] }
        guard !nextPositions.isEmpty else { return .undecided(.nextWordMissing) }
        guard nextPositions.contains(at + 1) else { return .undecided(.notAdjacent) }
        let after = at + 1
        let trailing = tokens[at].reversed().prefix { !$0.isLetter && !$0.isNumber }
        if trailing.contains(where: { ".!?…".contains($0) }) { return .mark(.period) }
        // The head's recognizer heard the whole utterance and wrote a
        // question or an exclamation; a window that heard less does not
        // take that mark away.
        if head.reversed().first(where: { !"\"'’”)]".contains($0) }).map({ "?!".contains($0) }) == true { return .undecided(.questionKept) }
        if trailing.contains(where: { ",;:—–".contains($0) }) { return .mark(.comma) }
        // No mark: applying `.nothing` lowers the next's opening capital, so
        // the window must have heard that very word, in lower case. A word
        // the window skipped may be a name; a capital it kept is one; an
        // acronym ("IT") would come out "iT". Any of those leave the seam alone.
        guard aligned[headTail.count] == after else { return .undecided(.nameAfterNothing) }
        if tokens[after].first?.isUppercase == true, windowWords[after] != "i" { return .undecided(.nameAfterNothing) }
        if let opener = next.split(whereSeparator: \.isWhitespace).first, opener.dropFirst().contains(where: \.isUppercase) {
            return .undecided(.nameAfterNothing)
        }
        return .mark(.nothing)
    }

    /// The window's tokens without filler sounds; a mark on a dropped
    /// filler moves to the token before it when that one carries none.
    static func spokenTokens(_ window: String) -> [String] {
        var out: [String] = []
        for token in window.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard fillers.contains(words(token).joined()) else { out.append(token); continue }
            let mark = token.reversed().prefix { !$0.isLetter && !$0.isNumber }
            guard !mark.isEmpty, let last = out.last, last.last?.isLetter == true || last.last?.isNumber == true else { continue }
            out[out.count - 1] = last + String(mark.reversed())
        }
        return out
    }

    /// Two words match when spelled the same, when one is the other's
    /// contraction base ("i'm"/"i", "it's"/"it"), when they are one
    /// substitution apart at four letters or more, or one letter apart at
    /// six or more ("counsellor"/"counselor"). A short word is never
    /// bridged onto a longer one: "here" is not "there".
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if base(lhs) == base(rhs) { return true }
        let shorter = min(lhs.count, rhs.count), longer = max(lhs.count, rhs.count)
        guard longer - shorter <= 1, shorter >= 4, longer == shorter || shorter >= 6 else { return false }
        return editDistance(Array(lhs), Array(rhs)) <= 1
    }

    private static func base(_ word: String) -> Substring {
        word.split(separator: "'", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(word)
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1]
            for (col, right) in rhs.enumerated() {
                current.append(min(previous[col + 1] + 1, current[col] + 1, previous[col] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    /// The words alone — case and marks aside — as the benches count them.
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }

    /// Longest-common-subsequence alignment: index in `spoken` → index in `heard`.
    static func alignment(_ spoken: [String], _ heard: [String]) -> [Int: Int] {
        guard !spoken.isEmpty, !heard.isEmpty else { return [:] }
        var table = Array(repeating: Array(repeating: 0, count: heard.count + 1), count: spoken.count + 1)
        for row in stride(from: spoken.count - 1, through: 0, by: -1) {
            for col in stride(from: heard.count - 1, through: 0, by: -1) {
                table[row][col] = matches(spoken[row], heard[col]) ? table[row + 1][col + 1] + 1 : max(table[row + 1][col], table[row][col + 1])
            }
        }
        var out: [Int: Int] = [:]
        var row = 0, col = 0
        while row < spoken.count, col < heard.count {
            if matches(spoken[row], heard[col]) {
                out[row] = col; row += 1; col += 1
            } else if table[row + 1][col] >= table[row][col + 1] {
                row += 1
            } else {
                col += 1
            }
        }
        return out
    }
}
