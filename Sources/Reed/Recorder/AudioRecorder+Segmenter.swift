import Foundation

private let alog = Log(category: "audio")

/// Live segmentation glue (latency step 2, 2026-08-27): feeds each captured
/// buffer's loudness to `SpeechSegmenter` and, when it seals, hands the
/// sealed slice of the recording into `pendingSealed` — so recognition and
/// cleanup can run on it while the user is still speaking. The full
/// recording keeps accumulating exactly as before; `stopWithSegments()`
/// returns the whole WAV, the byte the unprocessed tail starts at, and any
/// seals not yet taken, all in one bufferQueue turn.
extension AudioRecorder {
    /// One sealed slice of the live recording, with its own loudness so the
    /// silence-artifact check judges it by itself, not by the previous
    /// recording's level (R10).
    struct SealedSegment {
        let wav: Data
        let reason: SpeechSegmenter.Reason
        let rmsDB: Double
        /// Where the slice sits in the recording's PCM (no header), the
        /// live seal points — kept in the review copy so a seam bench can
        /// read the audio across the seal exactly where the app sealed it
        /// (seam experiment, 2026-09-10). Nil only for segments tests build.
        let pcmRange: Range<Int>?

        init(wav: Data, reason: SpeechSegmenter.Reason, rmsDB: Double, pcmRange: Range<Int>? = nil) {
            self.wav = wav
            self.reason = reason
            self.rmsDB = rmsDB
            self.pcmRange = pcmRange
        }
    }

    /// What stop() returns for an overlapped press: the full WAV as before,
    /// the byte the unprocessed tail starts at, and the seals the main
    /// actor had not taken yet — read in one bufferQueue turn.
    struct StopResult {
        let wav: Data
        let sealedOffset: Int
        let pending: [SealedSegment]
    }

    /// Called on `bufferQueue` right after a buffer is appended. Speech vs
    /// pause is the meter's own gate — RMS against the self-calibrating
    /// noise floor — so it inherits the meter's mic/gain independence.
    func segmentIfDue(rms: Float) {
        guard segmentingEnabled else { return }
        let db = rms > 1e-6 ? 20 * log10(Double(rms)) : -120
        let isSpeech = db > meterNoiseFloorDB + Self.meterGateDB
        let start = segmenter.segmentStartByte
        // The segmenter counts bytes; what was appended is what it observes.
        let appended = pcmBuffer.count - segmenter.observedBytes
        guard appended > 0, let seal = segmenter.observe(isSpeech: isSpeech, db: db, bytes: appended) else { return }
        guard seal.end > start, seal.end <= pcmBuffer.count else { return }
        let slice = pcmBuffer.subdata(in: start..<seal.end)
        let wav = WAVWriter.wrap(pcm: slice, sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        alog.info("segment sealed (\(String(describing: seal.reason))): \(slice.count / 32) ms (bytes \(start)..<\(seal.end)), next from \(seal.nextStart)")
        pendingSealed.append(SealedSegment(wav: wav, reason: seal.reason, rmsDB: LongAudioChunker.rmsDB(slice), pcmRange: start..<seal.end))
        if let notify = onSegmentSealed {
            DispatchQueue.main.async { notify() }
        }
    }

    /// Arm live segmentation for a press. `onSealed` fires on the main
    /// thread when a segment is waiting; the caller takes it with
    /// `takeSealedSegments()`.
    func armSegmenting(onSealed: @escaping () -> Void) {
        bufferQueue.sync {
            segmenter = SpeechSegmenter()
            pendingSealed = []
            segmentingEnabled = true
            onSegmentSealed = onSealed
        }
    }

    func disarmSegmenting() {
        bufferQueue.sync {
            segmentingEnabled = false
            onSegmentSealed = nil
        }
    }

    /// Every segment sealed since the last take, in order.
    func takeSealedSegments() -> [SealedSegment] {
        bufferQueue.sync {
            let taken = pendingSealed
            pendingSealed = []
            return taken
        }
    }
}
