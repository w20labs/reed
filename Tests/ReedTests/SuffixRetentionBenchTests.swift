import XCTest
@testable import Reed

/// Investigation (2026-09-07): a slice shaped short speech · pause · more
/// speech came back from the recognizer without the words after the pause
/// on one real recording, while the whole recording and the post-pause
/// slice alone were complete. This bench measures where the words go, on
/// identical audio, stage by stage — raw recognition, denoise then
/// recognition, the production tail path — over a matrix of fragment and
/// pause lengths, with controls: no pause, the post-pause part alone, the
/// whole take. Synthetic slices are built from the voice-tests clips
/// (references known); real ones from the corpus recordings around the
/// recorder's own seal offsets, where the expected suffix is the raw
/// transcript of the post-pause part alone. Counts only: no transcript
/// reaches the log. A recognition that throws is `SX|failed` and fails
/// the run; every planned cell prints a line.
///
/// Gated: REED_SUFFIX_BENCH=1 swift test --filter SuffixRetentionBenchTests
///        REED_SUFFIX_STAGE=synthetic|corpus (default: both) · REED_VOICE_ROOT · REED_REVIEW_CORPUS_DIR
///
///   SX|syn|<pair>|<frag_ms>|<pause_ms>|<arm>|<suffix_ref_words>|<suffix_found>|<words_before_suffix>|<ms>
///   SX|ctl|<pair>|<kind>|<arm>|<suffix_ref_words>|<suffix_found>|<ms>
///   SX|corpus|<copy>|<frag_ms>|<pause_ms>|<arm>|<suffix_expected>|<suffix_found>|<ms>
///   SX|cell|<stage>|<arm>|<frag_ms>|<pause_ms>|<n>|<mean_retention>
///   SX|tally|synthetic=<n> corpus=<n> failed=<n> lost_cells=<n>
final class SuffixRetentionBenchTests: XCTestCase {
    private let root = VoiceCorpus.root
    private static let fragmentsMs = [300, 600, 1_000, 1_500, 2_000, 3_000]
    private static let pausesMs = [500, 700, 1_000, 1_500]
    private static let pairs = [("01", "02"), ("03", "04"), ("05", "06")]
    private static let arms = ["raw", "denoised", "production"]

    @MainActor
    func testSuffixRetentionByStage() async throws {
        guard ProcessInfo.processInfo.environment["REED_SUFFIX_BENCH"] == "1" else {
            throw XCTSkip("set REED_SUFFIX_BENCH=1 to run (~3 min, real recognizer)")
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let stage = ProcessInfo.processInfo.environment["REED_SUFFIX_STAGE"] ?? "both"
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        defer { if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) } else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) } }
        UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
        let coordinator = BenchReplay.makeCoordinator()
        try await BenchDenoise.require()   // denoise proven to run (review 2026-09-08)
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        if #available(macOS 26.0, *) { AICleanup.prewarm() }
        var ai = false
        if #available(macOS 26.0, *) { ai = AICleanup.isAvailable }
        print("SX|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|stage=\(stage)|ai=\(ai)|tone_db=-60")
        var cells: [String: [Double]] = [:]
        var synthetic = 0, corpus = 0, failed = 0

        /// One slice through one arm: the transcript's words, or nil on a throw.
        func recognize(_ pcm: Data, arm: String) async -> (words: [String], ms: Int)? {
            let wav = BenchReplay.wrap(pcm)
            let t0 = Date()
            do {
                let text: String
                switch arm {
                case "raw": text = try await Coordinator.transcribe(wav: wav)
                case "denoised":
                    let (audio, outcome) = await Denoiser.shared.processReporting(wav: wav)
                    BenchDenoise.assertProcessed(outcome, "denoised arm")
                    text = try await Coordinator.transcribe(wav: audio)
                default:
                    guard let out = await coordinator.cleanSegment(wav: wav, rmsDB: BenchReplay.recordingLevel(pcm)) else { return nil }
                    text = out
                }
                return (BenchReplay.words(text), Int(Date().timeIntervalSince(t0) * 1000))
            } catch { return nil }
        }
        func retention(_ reference: [String], in words: [String]) -> (found: Int, before: Int) {
            let alignment = SeamRulesBenchTests.alignment(reference, words)
            let firstAligned = alignment.values.min() ?? words.count
            return (alignment.count, firstAligned)
        }

        if stage != "corpus" {
            let refs = try clipReferences()
            for (a, b) in Self.pairs {
                let speechA = Self.trimmed(try clip(a)), speechB = Self.trimmed(try clip(b))
                let suffixRef = BenchReplay.words(refs[b] ?? "")
                let key = "\(a)>\(b)"
                // Controls: the post-pause part alone; the whole take with a 1 s pause; no pause at all with a 1 s fragment.
                let controls: [(String, Data)] = [
                    ("post-pause-only", speechB),
                    ("whole-take", speechA + Self.tone(ms: 1_000) + speechB),
                    ("no-pause-1000", speechA.suffix(1_000 * 32) + speechB)
                ]
                for (kind, pcm) in controls {
                    for arm in Self.arms {
                        guard let got = await recognize(pcm, arm: arm) else { failed += 1; print("SX|failed|ctl|\(key)|\(kind)|\(arm)"); continue }
                        let r = retention(suffixRef, in: got.words)
                        print("SX|ctl|\(key)|\(kind)|\(arm)|\(suffixRef.count)|\(r.found)|\(got.ms)")
                        cells["synthetic|\(arm)|ctl-\(kind)", default: []].append(Double(r.found) / Double(max(1, suffixRef.count)))
                    }
                }
                for frag in Self.fragmentsMs {
                    for pause in Self.pausesMs {
                        let pcm = speechA.suffix(frag * 32) + Self.tone(ms: pause) + speechB
                        for arm in Self.arms {
                            guard let got = await recognize(pcm, arm: arm) else { failed += 1; print("SX|failed|syn|\(key)|\(frag)|\(pause)|\(arm)"); continue }
                            synthetic += 1
                            let r = retention(suffixRef, in: got.words)
                            print("SX|syn|\(key)|\(frag)|\(pause)|\(arm)|\(suffixRef.count)|\(r.found)|\(r.before)|\(got.ms)")
                            cells["synthetic|\(arm)|\(frag)|\(pause)", default: []].append(Double(r.found) / Double(max(1, suffixRef.count)))
                        }
                    }
                }
            }
        }

        if stage != "synthetic" {
            // Real speech: every recording whose copy sealed at least once at a pause.
            // The tail as the recorder cut it is the post-pause control; the slice
            // starting `frag` ms earlier holds the fragment, the pause, the tail.
            for copy in try corpusRecordings() {
                let wav = try Data(contentsOf: copy.audio)
                guard wav.count > 44 else { continue }
                let pcm = wav.subdata(in: 44..<wav.count)
                let tailStart = min(copy.tailStartMs * 32, pcm.count)
                guard tailStart > 0, pcm.count - tailStart > 16_000 else { print("SX|skipped|\(copy.id)|no-tail"); continue }
                let tail = pcm.subdata(in: tailStart..<pcm.count)
                guard let expected = await recognize(tail, arm: "raw"), !expected.words.isEmpty else { failed += 1; print("SX|failed|corpus|\(copy.id)|control"); continue }
                let pauseMs = Self.leadingSilenceMs(tail)
                print("SX|corpus|\(copy.id)|0|\(pauseMs)|raw|\(expected.words.count)|\(expected.words.count)|\(expected.ms)")
                for frag in [500, 1_000, 1_500, 2_500] where tailStart >= frag * 32 {
                    let slice = pcm.subdata(in: (tailStart - frag * 32)..<pcm.count)
                    for arm in Self.arms {
                        guard let got = await recognize(slice, arm: arm) else { failed += 1; print("SX|failed|corpus|\(copy.id)|\(frag)|\(arm)"); continue }
                        corpus += 1
                        let r = retention(expected.words, in: got.words)
                        print("SX|corpus|\(copy.id)|\(frag)|\(pauseMs)|\(arm)|\(expected.words.count)|\(r.found)|\(got.ms)")
                        cells["corpus|\(arm)|\(frag)|\(pauseMs >= 700 ? "pause" : "short")", default: []].append(Double(r.found) / Double(max(1, expected.words.count)))
                    }
                }
            }
        }

        print("SX|denoise|\(BenchDenoise.tally)")
        var lost = 0
        for key in cells.keys.sorted() {
            let values = cells[key] ?? []
            let mean = values.reduce(0, +) / Double(max(1, values.count))
            if mean < 0.999 { lost += 1 }
            print("SX|cell|\(key)|\(values.count)|\(String(format: "%.3f", mean))")
        }
        print("SX|tally|synthetic=\(synthetic) corpus=\(corpus) failed=\(failed) lost_cells=\(lost)")
        XCTAssertEqual(failed, 0, "\(failed) recognitions failed: they are not in any denominator")
    }

    // MARK: - Audio helpers

    private func clip(_ id: String) throws -> Data {
        let wav = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips/clip\(id).wav"))
        return wav.subdata(in: 44..<wav.count)
    }

    private func clipReferences() throws -> [String: String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips_ref.json"))
        let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var out: [String: String] = [:]
        for item in items { if let id = item["id"] as? String, let text = item["verbatim"] as? String { out[id] = text } }
        return out
    }

    /// Room tone at −60 dBFS: a pause as a microphone hears it, not digital zero.
    static func tone(ms: Int) -> Data {
        var seed: UInt32 = 7
        let samples: [Int16] = (0..<(ms * 16)).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int16(truncatingIfNeeded: Int(seed >> 16) % 81 - 40)
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The clip without its leading and trailing silence (buffers under −45 dB).
    static func trimmed(_ pcm: Data) -> Data {
        let buffer = 20 * 32
        var first = 0, last = pcm.count
        var offset = 0
        var seenSpeech = false
        while offset < pcm.count {
            let end = min(offset + buffer, pcm.count)
            if LongAudioChunker.rmsDB(pcm.subdata(in: offset..<end)) > -45 {
                if !seenSpeech { first = offset; seenSpeech = true }
                last = end
            }
            offset = end
        }
        return seenSpeech ? pcm.subdata(in: first..<last) : pcm
    }

    /// Milliseconds of near-silence at the start of a slice.
    static func leadingSilenceMs(_ pcm: Data) -> Int {
        let buffer = 20 * 32
        var offset = 0
        while offset + buffer <= pcm.count, LongAudioChunker.rmsDB(pcm.subdata(in: offset..<(offset + buffer))) <= -45 { offset += buffer }
        return offset / 32
    }

    // MARK: - Corpus

    struct Recording {
        let id: String
        let audio: URL
        /// Where the recorder's last seal left the tail, from the copy's segment durations.
        let tailStartMs: Int
    }

    private func corpusRecordings() throws -> [Recording] {
        let dir = ReviewCorpusBenchTests.corpusDirectory()
        var out: [Recording] = []
        for copy in LocalReviewStore.copies(in: dir) {
            let record = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Data(contentsOf: copy.url))
            let segments = record.segments.sorted { $0.index < $1.index }
            guard segments.count >= 2, segments.dropLast().last?.boundary == .pause, let audioName = record.audioFile else { continue }
            let audio = dir.appending(path: audioName)
            guard FileManager.default.fileExists(atPath: audio.path) else { continue }
            let tailStart = segments.dropLast().reduce(0) { $0 + ($1.audioMs ?? 0) }
            out.append(Recording(id: copy.url.lastPathComponent, audio: audio, tailStartMs: tailStart))
        }
        return out
    }
}
