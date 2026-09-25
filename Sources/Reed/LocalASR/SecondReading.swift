import Foundation

/// A second reading for a collapsed slice (investigation 2026-09-08). For
/// particular start offsets of a slice of real speech, the recognizer
/// returns an empty or one-to-two-word transcript for several seconds of
/// words — deterministically on bytes, never on the whole recording, and
/// 40 ms of −60 dBFS room tone in front of the slice returns them. No
/// unconditional treatment is safe (padding or fading every slice moves
/// the collapses and changes healthy transcripts), so every slice is read
/// as cut and, when the flag is on, once more with the prefix; the first
/// reading is kept unless it holds at most half the words of a second
/// reading of at least `minAlternateWords` words that is at least
/// `minGain` words longer. Measured before shipping on the developer's
/// corpus: 34 of 39 collapsed slices recovered, 5 remain, no healthy
/// reading replaced among 1062. The selected string is returned verbatim;
/// words are counted only to choose. FluidAudio 0.15.6 does not change
/// the collapse; the report is docs/bench/upstream-slice-start-collapse.md.
enum SecondReading {
    /// Remote kill switch, default ON. Local override:
    ///   defaults write com.local.reed reed.flagOverride.asr_second_reading -bool NO
    static let flag = "asr_second_reading"
    static let flagDefault = true
    /// The prefix: 40 ms of deterministic noise at about −60 dBFS, 16 kHz
    /// int16 — a pause as a microphone hears it, not digital zero.
    static let prefixMs = 40
    static let prefix: Data = {
        var seed: UInt32 = 7
        let samples: [Int16] = (0..<(prefixMs * 16)).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int16(truncatingIfNeeded: Int(seed >> 16) % 81 - 40)
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }()
    /// The second reading replaces the first only past these bounds: a
    /// longer second reading is not a better one, and a short command must
    /// not be traded for two invented words.
    static let minAlternateWords = 3
    static let minGain = 2

    struct Selection: Equatable {
        /// The reading kept, exactly as the recognizer returned it.
        let text: String
        let replaced: Bool
        let originalWords: Int
        /// nil: no second reading was made (flag off) or it failed.
        let alternateWords: Int?
    }

    /// Pure: which reading to keep.
    static func select(original: String, alternate: String?) -> Selection {
        let originalWords = wordCount(original)
        guard let alternate else { return Selection(text: original, replaced: false, originalWords: originalWords, alternateWords: nil) }
        let alternateWords = wordCount(alternate)
        let replace = originalWords * 2 <= alternateWords && alternateWords >= minAlternateWords && alternateWords - originalWords >= minGain
        return Selection(text: replace ? alternate : original, replaced: replace, originalWords: originalWords, alternateWords: alternateWords)
    }

    /// Test seam: sees every selection the production path makes, per
    /// piece, with the piece's length in bytes — so a bench can count what
    /// production decided inside a long recording rather than compare two
    /// whole transcripts (review 2026-09-08). nil in production.
    nonisolated(unsafe) static var selectionObserver: ((Selection, Int) -> Void)?

    /// The policy over a recognizer: the slice as cut first; with the flag
    /// on, the prefixed slice second. A failed second reading is ignored; a
    /// failed first reading propagates. Never more than two calls.
    static func read(_ pcm: Data, enabled: Bool, using recognize: (Data) async throws -> String) async throws -> Selection {
        let original = try await recognize(pcm)
        let selection: Selection
        if enabled {
            let alternate = try? await recognize(prefix + pcm)
            selection = select(original: original, alternate: alternate)
        } else {
            selection = select(original: original, alternate: nil)
        }
        selectionObserver?(selection, pcm.count)
        return selection
    }

    /// Words for counting only: letters, digits and apostrophes, case aside.
    static func wordCount(_ text: String) -> Int {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.count
    }
}
