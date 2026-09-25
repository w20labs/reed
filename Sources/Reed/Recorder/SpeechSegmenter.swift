import Foundation

/// Decides where a live recording can be cut into segments that are safe to
/// transcribe and clean WHILE the user keeps speaking (latency step 2,
/// 2026-08-27 — "overlap cleanup with speech"). Pure state machine: it is
/// fed one observation per tap buffer and answers with a byte offset to seal
/// at, or nothing. No audio, no timers, no threads — so the sealing rules
/// are unit-testable to the millisecond.
///
/// A seal happens at the end of a pause: speech was heard in the open
/// segment, the segment is at least `minSegment` long, and `minSilence` of
/// non-speech has followed the last speech. That is where a sentence
/// boundary lives. A speaker who never pauses is sealed at `maxSegment`
/// regardless (Whisper handles that length fine; the cut may land
/// mid-sentence, which the cleanup gate tolerates — it is the rare case).
/// The trailing segment is sealed by the caller at release, not here.
struct SpeechSegmenter {
    /// Non-speech that must follow speech before a cut. Below ~500 ms a cut
    /// lands inside a breath or a comma; above ~1 s the overlap gain erodes.
    static let minSilenceMs = 700
    /// A segment shorter than this is not worth a model round-trip of its
    /// own and is more likely a fragment than a sentence.
    static let minSegmentMs = 2_000
    /// Hard cap for a speaker who never pauses. Kept short on purpose: what
    /// the user waits for at release is the TAIL — everything after the last
    /// cut — so a long cap means a long wait on a run-on (30 s measured 3.6 s
    /// after release vs ~3 s at 20 s; run-on bench 2026-08-27). Quality at
    /// the cut is the quiet-point search's job, not the cap's.
    static let maxSegmentMs = 20_000
    /// At the cap, cut at the QUIETEST buffer inside this trailing window
    /// rather than at the cap byte itself (run-on bench 2026-08-27: a fixed
    /// cut landed mid-word — "install. Of scrambling" for "instead of").
    /// Between words the level dips even when the speaker never pauses.
    static let capSearchWindowMs = 3_000

    /// A cap cut lands mid-sentence by definition, so the NEXT segment
    /// starts before the cut — at the quietest buffer in this window ahead
    /// of it, i.e. the previous word boundary — so the recognizer opens on a
    /// whole word instead of a cold mid-phrase onset (run-on bench
    /// 2026-08-28: a segment opening at a hard cut hallucinated "start.",
    /// and a fixed 300 ms pre-roll that began mid-word produced "start to").
    /// The duplicated word(s) are trimmed at assembly (`Coordinator.trimOverlap`).
    static let capPreRollMinMs = 200
    static let capPreRollMaxMs = 900
    /// Bench switch (finding 2, 2026-08-29): does Parakeet still need the
    /// pre-roll the recognizer needs? Off = the next segment starts at the cut.
    nonisolated(unsafe) static var capPreRollEnabled = true

    /// Bytes of 16 kHz mono int16 audio per millisecond.
    static let bytesPerMs = 32

    /// Why a segment was sealed — a pause is a sentence boundary, a cap cut
    /// is not, and assembly treats the two differently.
    enum Reason: Equatable { case pause, cap }

    /// A sealed segment: `end` is the byte the sealed audio runs to; the next
    /// segment starts at `nextStart` (before `end` when a cap cut pre-rolls).
    struct Seal: Equatable {
        let end: Int
        let nextStart: Int
        let reason: Reason
    }

    /// Where the open segment starts, in captured bytes.
    private(set) var segmentStartByte = 0
    /// Total captured bytes observed so far.
    private(set) var observedBytes = 0
    /// Bytes at which speech was last heard (nil: none in this segment yet).
    private var lastSpeechByte: Int?
    /// Bytes at which the current run of silence began (nil: speaking, or
    /// nothing heard yet).
    private var silenceStartByte: Int?
    /// Recent buffers as (start byte, level dB), kept for the cap search.
    private var recent: [(byte: Int, db: Double)] = []

    /// Feed one buffer: whether it carried speech, its level, and how many
    /// bytes it added. Returns the seal if a cut is due — the caller emits
    /// `pcm[segmentStart..<seal.end]` and the next segment starts at
    /// `seal.nextStart`.
    mutating func observe(isSpeech: Bool, db: Double = 0, bytes: Int) -> Seal? {
        let bufferStart = observedBytes
        observedBytes += bytes
        recent.append((bufferStart, db))
        let windowStart = observedBytes - Self.capSearchWindowMs * Self.bytesPerMs
        recent.removeAll { $0.byte < windowStart }
        if isSpeech {
            lastSpeechByte = observedBytes
            silenceStartByte = nil
        } else if lastSpeechByte != nil, silenceStartByte == nil {
            silenceStartByte = bufferStart
        }

        let segmentMs = (observedBytes - segmentStartByte) / Self.bytesPerMs
        guard let lastSpeech = lastSpeechByte else { return nil }   // nothing said yet

        if segmentMs >= Self.maxSegmentMs {
            // Quietest recent buffer that still leaves a real segment behind.
            let floor = segmentStartByte + Self.minSegmentMs * Self.bytesPerMs
            let quietest = recent.filter { $0.byte > floor }.min { $0.db < $1.db }
            return seal(at: quietest?.byte ?? observedBytes, reason: .cap)
        }
        // `minSegment` measures what was SPOKEN (start → where the pause
        // began), not the pause itself — 1 s of speech plus 1.5 s of silence
        // is still a fragment.
        let spokenMs = (lastSpeech - segmentStartByte) / Self.bytesPerMs
        if let silenceStart = silenceStartByte,
           spokenMs >= Self.minSegmentMs,
           (observedBytes - silenceStart) / Self.bytesPerMs >= Self.minSilenceMs {
            // Cut at the START of the pause, not its end: the silence belongs
            // to neither sentence, and leading silence in the next segment
            // is harmless while trailing silence in this one just wastes
            // recognizer time.
            return seal(at: silenceStart, reason: .pause)
        }
        return nil
    }

    /// Bytes of audio in the open (unsealed) segment.
    var openSegmentBytes: Int { observedBytes - segmentStartByte }

    private mutating func seal(at offset: Int, reason: Reason) -> Seal {
        let previousStart = segmentStartByte
        var nextStart = offset
        if reason == .cap, Self.capPreRollEnabled {
            let lo = offset - Self.capPreRollMaxMs * Self.bytesPerMs
            let hi = offset - Self.capPreRollMinMs * Self.bytesPerMs
            let boundary = recent.filter { $0.byte >= lo && $0.byte <= hi }.min { $0.db < $1.db }
            nextStart = boundary?.byte ?? hi
        }
        segmentStartByte = max(nextStart, previousStart)
        lastSpeechByte = nil
        silenceStartByte = nil
        // Audio after the cut point already belongs to the new segment: if
        // speech was heard there, the new segment starts "mid-speech".
        if let last = recent.last, last.byte >= segmentStartByte, lastSpeechByte == nil {
            lastSpeechByte = observedBytes
        }
        recent.removeAll { $0.byte < segmentStartByte }
        return Seal(end: offset, nextStart: segmentStartByte, reason: reason)
    }
}
