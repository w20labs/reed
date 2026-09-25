import XCTest
@testable import Reed

/// Acceptance bench for overlapped cleanup (latency step 2): replays the
/// ~83 s long input through the live segmenter AT REAL-TIME PACE — as if
/// the user were speaking — so head segments get recognized and cleaned
/// while later audio is still "arriving". At the simulated release, only
/// the tail is outstanding; the number reported is the wait AFTER release,
/// which is what the user feels. The same audio then runs single-pass for
/// the before number.
///
/// Gated: REED_OVERLAP_BENCH=1 swift test --filter OverlapBenchTests
///        REED_OVERLAP_RUNS=2 (default) · REED_VOICE_ROOT=<corpus>
///        REED_OVERLAP_INPUT=<wav>  replay one file instead of the corpus concatenation
///
/// Output lines:
///   OV|overlap|<run>|<segments>|<after_release_ms>|<text>
///   OV|single|<run>|<after_release_ms>|<text>
///   OV|clip|<id>|<segments>|<overlap_ms>|<single_ms>|<same>|<texts>   (REED_OVERLAP_PERCLIP=1)
final class OverlapBenchTests: XCTestCase {
    private let root = VoiceCorpus.root

    @MainActor
    func testOverlapAgainstSinglePass() async throws {
        guard ProcessInfo.processInfo.environment["REED_OVERLAP_BENCH"] == "1" else {
            throw XCTSkip("set REED_OVERLAP_BENCH=1 to run (real-time replay, ~3 min per run)")
        }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else { throw XCTSkip("no Foundation Models") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let runs = try BenchEnv.count("REED_OVERLAP_RUNS", default: 2)  // positive, or the bench fails here, before any model loads
        let pcm = try concatenatedPCM()
        let audioSeconds = Double(pcm.count) / 32_000
        let savedPreRoll = SpeechSegmenter.capPreRollEnabled
        defer { SpeechSegmenter.capPreRollEnabled = savedPreRoll }
        SpeechSegmenter.capPreRollEnabled = ProcessInfo.processInfo.environment["REED_OVERLAP_PREROLL"] != "0"
        print("OV|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|audio=\(String(format: "%.1f", audioSeconds))s|preroll=\(SpeechSegmenter.capPreRollEnabled)")

        // The AI cleanup tier, explicitly: the test process has its own
        // defaults domain, where the tier defaults to rules-only — the first
        // run of this bench measured ASR alone in both arms without noticing.
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
        defer {
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        XCTAssertEqual(LocalCleanup.tier, .ai)
        let coordinator = BenchReplay.makeCoordinator()
        try await BenchDenoise.require()   // denoise proven to run (review 2026-09-08)
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        AICleanup.prewarm()
        // Warm-up (unmeasured) on the first clip.
        _ = await coordinator.cleanSegment(wav: wrap(pcm.prefix(9 * 32_000)), rmsDB: BenchReplay.recordingLevel(pcm.prefix(9 * 32_000)))

        for run in 1...runs {
            // --- Overlapped: replay at real-time pace through the segmenter ---
            guard let replay = await BenchReplay.overlapped(pcm, coordinator: coordinator) else { XCTFail("replay failed even single-pass"); return }
            let (segments, after, text) = (replay.segments, replay.afterMs, replay.text)
            print("OV|overlap|\(run)|\(segments)|\(after)|\(text.replacingOccurrences(of: "\n", with: " ⏎ "))")

            // --- Single-pass on the same audio ---
            let s0 = Date()
            guard let single = await coordinator.cleanSegment(wav: wrap(pcm), rmsDB: BenchReplay.recordingLevel(pcm)) else { XCTFail("single-pass failed"); return }
            print("OV|single|\(run)|\(Int(Date().timeIntervalSince(s0) * 1000))|\(single.replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
    }

    /// Per-clip arm (REED_OVERLAP_PERCLIP=1): every everyday clip on its own
    /// through the segmenter, to MEASURE that short dictations are
    /// unchanged rather than assume it. One line per clip:
    ///   OV|clip|<id>|<segments>|<overlap_ms>|<single_ms>|<same>|<overlap text>|<single text>
    @MainActor
    func testEverydayClipsThroughTheSegmenter() async throws {
        guard ProcessInfo.processInfo.environment["REED_OVERLAP_PERCLIP"] == "1" else {
            throw XCTSkip("set REED_OVERLAP_PERCLIP=1 to run")
        }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else { throw XCTSkip("no Foundation Models") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
        defer {
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        XCTAssertEqual(LocalCleanup.tier, .ai)
        let coordinator = BenchReplay.makeCoordinator()
        try await BenchDenoise.require()   // denoise proven to run (review 2026-09-08)
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        AICleanup.prewarm()
        print("OV|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|perclip")
        for id in (1...10).map({ String(format: "%02d", $0) }) {
            let clip = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips/clip\(id).wav"))
            let pcm = clip.subdata(in: 44..<clip.count)
            _ = await coordinator.cleanSegment(wav: wrap(pcm), rmsDB: BenchReplay.recordingLevel(pcm))   // warm, unmeasured
            guard let replay = await BenchReplay.overlapped(pcm, coordinator: coordinator) else { XCTFail("replay failed even single-pass"); return }
            let (segments, after, text) = (replay.segments, replay.afterMs, replay.text)
            // Idle parity: the overlapped arm's tail ran after the clip's
            // duration of (simulated) speaking; give single-pass the same
            // idle so neither arm gets a warmer model (first per-clip run
            // measured a ~0.85 s idle penalty on the overlapped arm alone).
            try? await Task.sleep(nanoseconds: UInt64(Double(pcm.count) / 32_000 * 1_000_000_000))
            let s0 = Date()
            guard let single = await coordinator.cleanSegment(wav: wrap(pcm), rmsDB: BenchReplay.recordingLevel(pcm)) else { XCTFail("single-pass failed on clip \(id)"); return }
            let singleMs = Int(Date().timeIntervalSince(s0) * 1000)
            print("OV|clip|\(id)|\(segments)|\(after)|\(singleMs)|\(text == single)|\(text)|\(single)")
        }
    }

    // MARK: helpers

    private func concatenatedPCM() throws -> Data {
        // REED_OVERLAP_INPUT=<wav> replays one arbitrary 16 kHz mono int16
        // WAV instead — e.g. voice-tests/long_runon.wav, a ~40 s single
        // sentence with no pauses, which exercises the 20 s cap (mid-sentence
        // cuts) rather than pause boundaries.
        if let path = ProcessInfo.processInfo.environment["REED_OVERLAP_INPUT"] {
            let wav = try Data(contentsOf: URL(fileURLWithPath: path))
            return wav.subdata(in: 44..<wav.count)
        }
        var pcm = Data()
        for id in (1...10).map({ String(format: "%02d", $0) }) {
            let clip = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips/clip\(id).wav"))
            pcm.append(clip.subdata(in: 44..<clip.count))
            pcm.append(Data(count: Int(16_000 * 2 * 0.9)))   // a natural pause
        }
        return pcm
    }

    private func wrap(_ pcm: Data) -> Data { BenchReplay.wrap(pcm) }

}
