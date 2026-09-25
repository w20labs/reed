import XCTest
@testable import Reed

/// Replays a recording through the live segmenter at wall-clock pace, the
/// way the user's speech arrives — shared by the overlap bench and the
/// review-corpus bench (2026-09-06), so both measure the same pipeline.
enum BenchReplay {
    /// What one replay produced: the text the app would have delivered.
    struct Result: Equatable {
        /// Segments incl. the tail (1 when single-pass carried the take).
        let segments: Int
        /// Milliseconds after the simulated release.
        let afterMs: Int
        let text: String
        /// A segment failed and, as in production, single-pass on the whole
        /// recording produced the text instead.
        let fellBack: Bool
        /// The cleaned pieces assembly was given (empty after a fallback),
        /// so a bench can find every pause seam in the text.
        var pieces: [Coordinator.Piece] = []
    }

    /// Replay through the segmenter, the way `processLocalOverlapped` runs a
    /// press. The silence-artifact filter is handed the levels the app hands
    /// it, by the app's own measures: each head its own slice
    /// (`AudioRecorder+Segmenter`), the tail and single-pass the WHOLE
    /// recording (`recorder.lastRecordingRMSdB`). A failed tail falls back
    /// at once without waiting for the heads, as the release path does; a
    /// failed head falls back after the tail; either way single-pass on the
    /// whole recording is the text, and nil means even that failed — never
    /// placeholder text (reviews 2026-09-07).
    @MainActor
    static func overlapped(_ pcm: Data, coordinator: Coordinator, paced: Bool = true) async -> Result? {
        let session = OverlapSession()
        session.arm()
        let recordingDB = recordingLevel(pcm)
        var segmenter = SpeechSegmenter()
        var floorDB = 0.0
        var segmentStart = 0
        var offset = 0
        let bufferBytes = 85 * SpeechSegmenter.bytesPerMs
        let t0 = Date()
        while offset < pcm.count {
            let end = min(offset + bufferBytes, pcm.count)
            let chunk = pcm.subdata(in: offset..<end)
            let db = LongAudioChunker.rmsDB(chunk)
            // The meter's floor rule, simplified: instant drop, slow creep.
            if db < floorDB { floorDB = max(db, -90) } else if db < floorDB + 15 { floorDB = min(db, floorDB + 0.04) }
            let isSpeech = db > floorDB + AudioRecorder.meterGateDB
            if let seal = segmenter.observe(isSpeech: isSpeech, db: db, bytes: chunk.count) {
                let slice = pcm.subdata(in: segmentStart..<seal.end)
                let wav = wrap(slice), level = LongAudioChunker.rmsDB(slice)
                segmentStart = seal.nextStart
                session.enqueue(sealedBy: seal.reason) { await coordinator.cleanSegment(wav: wav, rmsDB: level) }
            }
            offset = end
            if paced {
                // Real-time pacing: wait until this buffer's wall-clock slot.
                let due = t0.addingTimeInterval(Double(offset) / 32_000)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
        }
        // Release, in the release path's order: the tail, THEN the heads —
        // a failed tail never waits for them — then assembly; or single-pass
        // on the whole recording, the heads cancelled as `abandonOverlap-
        // ForSinglePass` cancels them.
        let release = Date()
        let tailSlice = pcm.subdata(in: segmentStart..<pcm.count)
        let count = session.segmentCount + 1
        let boundaries = session.boundaries
        let tail = await coordinator.cleanSegment(wav: wrap(tailSlice), rmsDB: recordingDB)
        guard let tail, let heads = await session.collect() else {
            session.reset()
            guard let single = await coordinator.cleanSegment(wav: wrap(pcm), rmsDB: recordingDB) else { return nil }
            return Result(segments: 1, afterMs: Int(Date().timeIntervalSince(release) * 1000), text: single, fellBack: true)
        }
        session.reset()
        let pieces = zip(heads, boundaries).map { Coordinator.Piece(text: $0, sealedBy: $1) }
            + [Coordinator.Piece(text: tail, sealedBy: nil)]
        let text = await Coordinator.assembleSegments(pieces)
        return Result(segments: count, afterMs: Int(Date().timeIntervalSince(release) * 1000), text: text, fellBack: false, pieces: pieces)
    }

    /// The level the app's single-pass path hands the artifact filter for
    /// this recording: `recorder.lastRecordingRMSdB`, i.e. `RecordingLevels`
    /// over the whole take. The single-pass bench arm uses it too, so both
    /// arms meet the filter on the same terms.
    static func recordingLevel(_ pcm: Data) -> Double {
        RecordingLevels.measure(pcm: pcm).rmsDB
    }

    /// The test process has its own defaults domain, so Coordinator.init
    /// would open the onboarding window on every run; mark it completed.
    @MainActor
    static func makeCoordinator() -> Coordinator {
        let savedOnboarding = UserDefaults.standard.object(forKey: OnboardingState.completedKey)
        defer {
            if let savedOnboarding { UserDefaults.standard.set(savedOnboarding, forKey: OnboardingState.completedKey) }
            else { UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey) }
        }
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
        return Coordinator()
    }

    static func wrap(_ pcm: Data) -> Data {
        WAVWriter.wrap(pcm: pcm, sampleRate: 16_000, channels: 1, bitsPerSample: 16)
    }

    /// Word-level Levenshtein distance over the reference's length (0 = the
    /// same words in the same order; punctuation and case ignored) — the
    /// review bench's edit-distance measure, in Swift.
    static func normalizedEditDistance(_ produced: String, reference: String) -> Double {
        let a = words(produced), b = words(reference)
        guard !b.isEmpty else { return a.isEmpty ? 0 : 1 }
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where i <= a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return Double(row[b.count]) / Double(b.count)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }
}
