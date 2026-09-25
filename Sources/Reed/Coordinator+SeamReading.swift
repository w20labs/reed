import Foundation

/// The seam reading in the live pipeline (flag `cleanup_seam_reading`,
/// default OFF; see `SeamReading`). Before assembly, every pause seam
/// whose halves' seal points are known is read from the recording and its
/// verdict handed to `assembleSegments(verdicts:)`. The window goes
/// through the same stages as a segment — denoise, the one recognizer —
/// so the bench that drives this function measures what production does.
extension Coordinator {
    struct SeamReads: Equatable {
        /// Piece index → the mark for the pause seam BEFORE that piece.
        var verdicts: [Int: SeamMark] = [:]
        /// Seams read but not decided, and why.
        var undecided: [Int: SeamReading.Undecided] = [:]
        /// Pause seams with no seal points or too little audio on a side.
        var unread = 0
        /// Wall-clock per read seam, and for all of them.
        var msPerSeam: [Int: Int] = [:]
        var readMs = 0
    }

    /// `ranges[i]` is piece i's PCM byte range in `pcm`, nil when unknown.
    func readSeams(pieces: [Piece], ranges: [Range<Int>?], pcm: Data) async -> SeamReads {
        var out = SeamReads()
        let start = Date()
        // Byte ranges are offsets into the recording's PCM; a Data slice
        // (`wav.dropFirst(44)`) keeps its parent's indices, so it is
        // re-based before any offset is applied.
        let pcm = pcm.startIndex == 0 ? pcm : Data(pcm)
        for index in pieces.indices.dropFirst() where pieces[index - 1].sealedBy == .pause {
            let head = pieces[index - 1].text, next = pieces[index].text
            // A correction cue crossing the pause is assembly's own case —
            // both halves re-cleaned together, the verdict ignored — so it is
            // not read (review 2026-09-11, round 2).
            guard !head.isEmpty, !next.isEmpty, !SentenceChunker.opensWithCorrectionCue(next), index < ranges.count,
                  let headRange = ranges[index - 1], let nextRange = ranges[index],
                  let window = SeamReading.window(pcm: pcm, seal: headRange.upperBound,
                                                  headStart: headRange.lowerBound, nextEnd: nextRange.upperBound) else {
                out.unread += 1
                continue
            }
            let seamStart = Date()
            SeamReading.windowObserverForTests?(window)
            let wav = WAVWriter.wrap(pcm: window, sampleRate: 16_000, channels: 1, bitsPerSample: 16)
            let (denoised, _) = await denoiseStage(wav)
            guard let text = try? await Self.transcribe(wav: denoised) else { out.unread += 1; continue }
            switch SeamReading.decide(head: head, next: next, window: text) {
            case .mark where SentenceChunker.endsInNonFinalWord(head):
                // A head ending in a word no sentence ends in is a breath;
                // that rule owns the seam whatever the window says — a
                // comma or a period after "the" is wrong, and "nothing" is
                // what the breath rule does anyway (review 2026-09-10, #2).
                out.undecided[index] = .breathRule
            case .mark(let mark):
                out.verdicts[index] = mark
            case .undecided(let why):
                out.undecided[index] = why
            }
            out.msPerSeam[index] = Int(Date().timeIntervalSince(seamStart) * 1000)
        }
        out.readMs = Int(Date().timeIntervalSince(start) * 1000)
        return out
    }
}
