import XCTest
@testable import Reed

/// Long-input A/B for sentence coalescing (latency step 1, 2026-08-27): the
/// corpus clips are 5–10 s (1–4 sentences), so this builds a ~77 s dictation
/// by concatenating all ten (same 16 kHz mono int16 WAV format) and runs the
/// SHIPPED pipeline — denoise → ASR → vocabulary → cleanup — with the flag
/// OFF and ON, off then on, same order each run — read deltas with that in mind.
///
/// Gated: REED_LONG_BENCH=1 swift test --filter LongInputBenchTests
///        REED_LONG_RUNS=5 (default) · REED_VOICE_ROOT=<corpus>
///
/// Output lines (one per arm per run):
///   LI|<arm>|<run>|<audio_s>|<asr_ms>|<chunks>|<calls>|<cleanup_ms>|<e2e_ms>|<path>|<reason>|<text>
///   LIRAW|<arm>|<run>|<raw transcript>
final class LongInputBenchTests: XCTestCase {
    private let root = VoiceCorpus.root

    func testLongInputAB() async throws {
        guard ProcessInfo.processInfo.environment["REED_LONG_BENCH"] == "1" else {
            throw XCTSkip("set REED_LONG_BENCH=1 to run (loads on-device models)")
        }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else {
            throw XCTSkip("Apple Foundation Models unavailable")
        }
        // Line-buffered stdout: `swift test` block-buffers when piped, and
        // xctest's own "Test Case … passed" line then lands INSIDE a buffered
        // data line, corrupting it (lost 4 of 10 lines on 2026-08-27).
        setvbuf(stdout, nil, _IOLBF, 0)
        let wav = try concatenatedClips()
        let audioSeconds = Double(wav.count - 44) / 32_000
        print("LI|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|audio=\(String(format: "%.1f", audioSeconds))s")

        let runs = try BenchEnv.count("REED_LONG_RUNS", default: 5)  // positive, or the bench fails here, before any model loads
        try await BenchDenoise.require()   // denoise proven to run (review 2026-09-08)
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
        let overrideKey = FeatureFlags.overrideKey(for: LocalCleanup.coalesceFlag)
        defer {
            UserDefaults.standard.removeObject(forKey: overrideKey)
            if let savedTier {
                UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey)
            }
        }

        // Warm-up (unmeasured).
        AICleanup.prewarm()
        _ = await LocalCleanup.applyWithPath(to: try await BenchStage.run("warm-up recognition") { try await Coordinator.transcribe(wav: wav) })

        for run in 1...runs {
            for arm in ["off", "on"] {
                UserDefaults.standard.set(arm == "on", forKey: overrideKey)
                let coalesce = arm == "on"
                let t0 = Date()
                let denoised = await Denoiser.shared.process(wav: wav)
                let raw = try await BenchStage.run("recognition run \(run) coalesce \(coalesce)") { try await Coordinator.transcribe(wav: denoised) }
                let asrMs = ms(since: t0)
                let corrected = CorrectionSession().apply(raw).text
                let chunks = SentenceChunker.split(corrected, coalesce: coalesce, glueFragments: true)
                let t1 = Date()
                let outcome = await LocalCleanup.applyWithPath(to: corrected)
                let cleanupMs = ms(since: t1)
                let e2e = ms(since: t0)
                let oneLine = outcome.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                print("LI|\(arm)|\(run)|\(String(format: "%.1f", audioSeconds))|\(asrMs)|\(chunks.count)|\(chunks.count)|\(cleanupMs)|\(e2e)|\(outcome.path.rawValue)|\(outcome.reason ?? "-")|\(oneLine)")
                // The raw transcript too: on long audio Whisper is not perfectly
                // deterministic run to run, and an arm difference in the
                // CLEANED text must be attributable (ASR variance vs cleanup).
                print("LIRAW|\(arm)|\(run)|\(raw.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
    }

    /// All ten clips, PCM concatenated, one rewritten 44-byte RIFF header.
    private func concatenatedClips() throws -> Data {
        var pcm = Data()
        for id in (1...10).map({ String(format: "%02d", $0) }) {
            let clip = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips/clip\(id).wav"))
            XCTAssertGreaterThan(clip.count, 44)
            pcm.append(clip.subdata(in: 44..<clip.count))
            // 0.6 s of silence between clips — a natural pause, and a place
            // for the recognizer to seal a sentence.
            pcm.append(Data(count: Int(16_000 * 2 * 0.6)))
        }
        return WAVWriter.wrap(pcm: pcm, sampleRate: 16_000, channels: 1, bitsPerSample: 16)
    }

    private func ms(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}
