import Foundation

/// Cut a finished recording into pieces the recognizer is reliable on
/// (finding 1 of the 2026-08-29 rerun): Parakeet via FluidAudio drops
/// content, truncates, or returns nothing on audio much beyond 20 s — the
/// 86 s corpus take lost a sentence to "orthogon" and its last 20 s
/// entirely, a 43 s half came back empty — while every 20 s window of the
/// same audio transcribed correctly. Overlapped dictation already feeds it
/// ≤ 20 s segments; this applies the same cut rules (`SpeechSegmenter`:
/// a pause after enough speech, else the quietest moment before the cap)
/// offline, so the single-pass paths are safe at any length.
enum LongAudioChunker {
    /// Audio at or under this goes through in one piece.
    static let maxSeconds: Double = Double(SpeechSegmenter.maxSegmentMs) / 1000
    /// The tap's cadence, so the segmenter sees the same buffers it does live.
    static let bufferBytes = 85 * SpeechSegmenter.bytesPerMs

    /// One piece of a long recording: its byte range, and whether it opens
    /// at a cap cut — in which case it starts with the previous piece's last
    /// word (the segmenter's pre-roll) and the recognizer's output for the
    /// two must be trimmed at the seam, exactly as overlapped dictation does.
    struct Piece: Equatable {
        let range: Range<Int>
        let opensAtCapCut: Bool
    }

    /// Pieces of 16 kHz mono int16 PCM, in order. Pause cuts are exact;
    /// cap cuts pre-roll to the previous word gap (finding 2 of the
    /// 2026-08-29 rerun: Parakeet completes a truncated phrase — "we are
    /// going to be able to" — and the duplicate the pre-roll creates is the
    /// evidence the seam trim needs to remove it).
    static func pieces(pcm: Data) -> [Piece] {
        guard Double(pcm.count) / 32_000 > maxSeconds else { return [Piece(range: 0..<pcm.count, opensAtCapCut: false)] }
        var segmenter = SpeechSegmenter()
        var floorDB = 0.0
        var start = 0
        var offset = 0
        var opensAtCap = false
        var out: [Piece] = []
        while offset < pcm.count {
            let end = min(offset + bufferBytes, pcm.count)
            let db = rmsDB(pcm.subdata(in: offset..<end))
            // The meter's floor rule, simplified: instant drop, slow creep.
            if db < floorDB { floorDB = max(db, -90) } else if db < floorDB + 15 { floorDB = min(db, floorDB + 0.04) }
            let isSpeech = db > floorDB + AudioRecorder.meterGateDB
            if let seal = segmenter.observe(isSpeech: isSpeech, db: db, bytes: end - offset), seal.end > start {
                out.append(Piece(range: start..<seal.end, opensAtCapCut: opensAtCap))
                start = seal.nextStart
                opensAtCap = seal.reason == .cap
            }
            offset = end
        }
        if start < pcm.count { out.append(Piece(range: start..<pcm.count, opensAtCapCut: opensAtCap)) }
        return out
    }

    static func rmsDB(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return -120 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count { let v = Double(samples[i]) / 32768; sum += v * v }
        }
        let rms = (sum / Double(count)).squareRoot()
        return rms > 1e-6 ? 20 * log10(rms) : -120
    }
}
