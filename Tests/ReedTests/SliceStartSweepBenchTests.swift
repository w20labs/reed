import CryptoKit
import XCTest
@testable import Reed

/// The recognizer's slice-start collapse (investigation 2026-09-08): for
/// particular start offsets, a slice of real speech comes back empty or
/// nearly so, deterministically on bytes. This bench sweeps the start of
/// every corpus tail over the 2.5 s before its seal in 40 ms steps, counts
/// the collapses, and records healthy controls — every recording whole,
/// as a word count and a content-free fingerprint — and latency, so two
/// recognizer versions can be compared on identical audio. Synthetic
/// pairs (voice-tests clips) run the same sweep as a control that has
/// never collapsed. Counts, offsets, fingerprints and timings only.
///
/// Gated: REED_SWEEP_BENCH=1 swift test --filter SliceStartSweepBenchTests
///        REED_REVIEW_CORPUS_DIR · REED_VOICE_ROOT · REED_SWEEP_STEP_MS=40 · REED_SWEEP_BACK_MS=2500
///        REED_SWEEP_DENOISE=on|off  denoise every slice before recognition as the app does (default on, proven
///                                   to run; off measures the raw recognizer)
///        REED_SWEEP_POLICY=on|off   the second reading (production, default on); with it on the tally is
///                                   held to asr.slice_collapse_per_mille_max in docs/bench/baselines.json
///        REED_SWEEP_PREPEND_MS=<n>  prepend n ms of room tone (−60 dBFS) to EVERY recognized slice and
///                                   recording — a candidate fix, measured on healthy audio too
///        REED_SWEEP_FADE_MS=<n>     fade the first n ms of every slice in (a linear ramp from silence):
///                                   removes the step a mid-waveform cut leaves, adds and shifts nothing
///
///   SS|env|<os>|fluidaudio=<version>|step=<ms>|back=<ms>
///   SS|whole|<copy>|<seconds>|<words>|<fingerprint>|<ms>
///   SS|tail|<copy>|<expected_words>|<offsets>|<collapses>|<windows_ms>|<p50_ms>
///   SS|synthetic|<pair>|<expected_words>|<offsets>|<collapses>|<windows_ms>
///   SS|tally|recordings=<n> offsets=<n> collapses=<n> affected=<n> per_mille=<x> whole_p50_ms=<n> slice_p50_ms=<n> synthetic_offsets=<n> synthetic_collapses=<n> step=<ms> back=<ms> synthetic_pairs=<n> synthetic_back=<ms>
/// The run fails unless every planned offset was measured and the synthetic controls did not collapse.
final class SliceStartSweepBenchTests: XCTestCase {
    private let root = VoiceCorpus.root
    /// The synthetic sweep's reach and pair count — the controls' planned coverage.
    static let syntheticReachMs = 3_000
    static let syntheticPairs = 3

    /// A collapse: at most half the expected words came back, and the
    /// transcript is at most half as long — a recognizer that stopped,
    /// not one that misheard.
    static func isCollapse(expected: [String], got: [String]) -> Bool {
        SeamRulesBenchTests.alignment(expected, got).count <= expected.count / 2 && got.count <= expected.count / 2
    }

    @MainActor
    func testSliceStartSweep() async throws {
        guard ProcessInfo.processInfo.environment["REED_SWEEP_BENCH"] == "1" else {
            throw XCTSkip("set REED_SWEEP_BENCH=1 to run (~5 min, real recognizer, local corpus)")
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let step = try BenchEnv.count("REED_SWEEP_STEP_MS", default: 40)
        let back = try BenchEnv.count("REED_SWEEP_BACK_MS", default: 2_500)
        // Coverage is validated before any model loads: a step past the
        // sweep's reach measures nothing and must not pass (review 2026-09-08).
        guard step <= back, step <= Self.syntheticReachMs else {
            XCTFail("REED_SWEEP_STEP_MS=\(step) exceeds the sweep's reach (back \(back) ms, synthetic \(Self.syntheticReachMs) ms): nothing would be measured")
            return
        }
        let prepend = Int(ProcessInfo.processInfo.environment["REED_SWEEP_PREPEND_MS"] ?? "0") ?? 0
        let fade = Int(ProcessInfo.processInfo.environment["REED_SWEEP_FADE_MS"] ?? "0") ?? 0
        let policy = (ProcessInfo.processInfo.environment["REED_SWEEP_POLICY"] ?? "on") == "on"
        let denoise = (ProcessInfo.processInfo.environment["REED_SWEEP_DENOISE"] ?? "on") == "on"
        if denoise { try await BenchDenoise.require() }   // proven to run (review 2026-09-08)
        let ceiling = policy ? try BenchBaselines.require(["asr", "slice_collapse_per_mille_max"]) : nil   // fail-closed, before any model loads
        let flagKey = FeatureFlags.overrideKey(for: SecondReading.flag)
        let savedFlag = UserDefaults.standard.object(forKey: flagKey)
        defer { if let savedFlag { UserDefaults.standard.set(savedFlag, forKey: flagKey) } else { UserDefaults.standard.removeObject(forKey: flagKey) } }
        UserDefaults.standard.set(policy, forKey: flagKey)
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        print("SS|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|fluidaudio=\(Self.fluidAudioVersion())|step=\(step)|back=\(back)|prepend=\(prepend)|fade=\(fade)|policy=\(policy ? "on" : "off")|denoise=\(denoise ? "on" : "off")")
        func recognize(_ pcm: Data) async throws -> (words: [String], ms: Int) {
            let t0 = Date()
            var audio = fade > 0 ? Self.fadedIn(pcm, ms: fade) : pcm
            if prepend > 0 { audio = SuffixRetentionBenchTests.tone(ms: prepend) + audio }
            var wav = BenchReplay.wrap(audio)
            if denoise {
                let (denoised, outcome) = await Denoiser.shared.processReporting(wav: wav)
                BenchDenoise.assertProcessed(outcome, "a slice")
                wav = denoised
            }
            let text = try await Coordinator.transcribe(wav: wav)
            return (BenchReplay.words(text), Int(Date().timeIntervalSince(t0) * 1000))
        }
        var recordings = 0, offsets = 0, collapses = 0, affected = 0
        var wholeMs: [Int] = [], sliceMs: [Int] = []
        let dir = ReviewCorpusBenchTests.corpusDirectory()
        for copy in LocalReviewStore.copies(in: dir) {
            let record = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Data(contentsOf: copy.url))
            guard let audioName = record.audioFile else { continue }
            let url = dir.appending(path: audioName)
            guard let wav = try? Data(contentsOf: url), wav.count > 44 + 32_000 else { continue }
            let pcm = wav.subdata(in: 44..<wav.count)
            let id = String(copy.url.lastPathComponent.prefix(19))
            let whole = try await recognize(pcm)
            wholeMs.append(whole.ms)
            print("SS|whole|\(id)|\(String(format: "%.1f", Double(pcm.count) / 32_000))|\(whole.words.count)|\(Self.fingerprint(whole.words))|\(whole.ms)")
            let segments = record.segments.sorted { $0.index < $1.index }
            guard segments.count >= 2, segments.dropLast().last?.boundary == .pause else { continue }
            let tailStart = segments.dropLast().reduce(0) { $0 + ($1.audioMs ?? 0) } * 32
            guard tailStart > (back + 1_000) * 32, pcm.count - tailStart > 16_000 else { continue }
            let expected = try await recognize(pcm.subdata(in: tailStart..<pcm.count)).words
            guard expected.count >= 3 else { continue }
            recordings += 1
            var windows: [Int] = []
            var ms: [Int] = []
            for offset in stride(from: step, through: back, by: step) {
                let got = try await recognize(pcm.subdata(in: (tailStart - offset * 32)..<pcm.count))
                ms.append(got.ms)
                if Self.isCollapse(expected: expected, got: got.words) { windows.append(offset) }
            }
            offsets += ms.count; collapses += windows.count; sliceMs += ms
            if !windows.isEmpty { affected += 1 }
            print("SS|tail|\(id)|\(expected.count)|\(ms.count)|\(windows.count)|\(windows)|\(Self.p50(ms))")
        }
        var synOffsets = 0, synCollapses = 0
        for (a, b) in [("01", "02"), ("03", "04"), ("07", "08")] {
            let speechA = SuffixRetentionBenchTests.trimmed(try clip(a)), speechB = SuffixRetentionBenchTests.trimmed(try clip(b))
            let expected = try await recognize(speechB).words
            var windows: [Int] = []
            var count = 0
            for frag in stride(from: step, through: Self.syntheticReachMs, by: step) {
                count += 1
                let got = try await recognize(speechA.suffix(frag * 32) + SuffixRetentionBenchTests.tone(ms: 700) + speechB)
                if Self.isCollapse(expected: expected, got: got.words) { windows.append(frag) }
            }
            synOffsets += count; synCollapses += windows.count
            print("SS|synthetic|\(a)>\(b)|\(expected.count)|\(count)|\(windows.count)|\(windows)")
        }
        print("SS|denoise|\(BenchDenoise.tally)")
        let perMille = offsets > 0 ? Double(collapses) * 1000 / Double(offsets) : 0
        print("SS|tally|recordings=\(recordings) offsets=\(offsets) collapses=\(collapses) affected=\(affected) per_mille=\(String(format: "%.1f", perMille)) whole_p50_ms=\(Self.p50(wholeMs)) slice_p50_ms=\(Self.p50(sliceMs)) synthetic_offsets=\(synOffsets) synthetic_collapses=\(synCollapses) step=\(step) back=\(back) synthetic_pairs=\(Self.syntheticPairs) synthetic_back=\(Self.syntheticReachMs)")
        // Coverage: every planned offset was measured, and the synthetic
        // controls — which have never collapsed — still do not.
        XCTAssertGreaterThan(recordings, 0, "no corpus tail to sweep")
        XCTAssertEqual(offsets, recordings * (back / step), "every corpus tail swept over every planned offset")
        XCTAssertEqual(synOffsets, Self.syntheticPairs * (Self.syntheticReachMs / step), "every synthetic offset measured")
        XCTAssertEqual(synCollapses, 0, "the synthetic controls collapsed: the recognizer or the bench changed")
        if let ceiling { XCTAssertLessThanOrEqual(perMille, ceiling, "collapsed slices per 1000 offsets over the committed ceiling") }
    }

    private func clip(_ id: String) throws -> Data {
        let wav = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips/clip\(id).wav"))
        return wav.subdata(in: 44..<wav.count)
    }

    /// A linear fade-in over the first `ms` of 16 kHz int16 PCM.
    static func fadedIn(_ pcm: Data, ms: Int) -> Data {
        let n = min(ms * 16, pcm.count / 2)
        guard n > 0 else { return pcm }
        var out = pcm
        out.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<n { samples[i] = Int16(Double(samples[i]) * Double(i) / Double(n)) }
        }
        return out
    }

    /// Content-free: the same words in the same order give the same eight hex digits.
    static func fingerprint(_ words: [String]) -> String {
        let digest = SHA256.hash(data: Data(words.joined(separator: " ").utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    static func p50(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    /// The pinned FluidAudio version, from Package.resolved beside the sources.
    static func fluidAudioVersion() -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Package.resolved")
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = json["pins"] as? [[String: Any]] else { return "unknown" }
        for pin in pins where (pin["identity"] as? String)?.lowercased() == "fluidaudio" {
            return (pin["state"] as? [String: Any])?["version"] as? String ?? "unknown"
        }
        return "unknown"
    }
}
