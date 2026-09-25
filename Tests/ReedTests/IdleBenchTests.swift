import XCTest
@testable import Reed

/// Lever 6 diagnosis (2026-08-28): the per-clip overlap bench showed a clip
/// processed after a few seconds of idle (the user speaking) takes ~0.85 s
/// longer than one processed back-to-back. Which stage pays, how the
/// penalty grows with idle, and does a tiny warm-up call at "press" remove
/// it? Everything else — model, clip, tier — is held constant.
///
/// Gated: REED_IDLE_BENCH=1 swift test --filter IdleBenchTests   (REED_IDLE_ARMS=natural,tickled to subset)
/// Lines: ID|<arm>|<idle_s>|<run>|asr_ms|clean_ms|warm_ms
///   arm natural: idle → ASR → cleanup (what a dictation does today)
///   arm fm-only: idle → cleanup on the cached raw (the FM's own idle cost)
///   arm warmed:  idle → warm-up (0.3 s silence ASR + 1-token FM), then ASR → cleanup
///   arm tickled: AICleanup.tickle() every 3 s THROUGH the idle (the keep-warm loop), then ASR → cleanup
final class IdleBenchTests: XCTestCase {
    private let root = VoiceCorpus.root

    @MainActor
    func testIdlePenalty() async throws {
        guard ProcessInfo.processInfo.environment["REED_IDLE_BENCH"] == "1" else { throw XCTSkip("set REED_IDLE_BENCH=1") }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else { throw XCTSkip("no Foundation Models") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
        defer {
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        XCTAssertEqual(LocalCleanup.tier, .ai)
        // Validated BEFORE any model loads (review 2026-09-01): an empty arm
        // list measured nothing and passed; an unknown arm ran as "natural"
        // under its own label; zero runs crashed on an empty range.
        let runs = try BenchEnv.count("REED_IDLE_RUNS", default: 3)
        let arms = try BenchEnv.list("REED_IDLE_ARMS", default: "natural,fm-only,warmed,tickled",
                                     allowed: ["natural", "fm-only", "warmed", "tickled"])
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        AICleanup.prewarm()
        let clip = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips/clip03.wav"))
        let silence = WAVWriter.wrap(pcm: Data(count: Int(16_000 * 2 * 0.3)), sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        // Warm everything once, unmeasured; keep the raw for the fm-only arm.
        let raw = try await BenchStage.run("warm-up recognition") { try await Coordinator.transcribe(wav: clip) }
        _ = await LocalCleanup.apply(to: raw)
        print("ID|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|clip03 \(String(format: "%.1f", Double(clip.count - 44) / 32_000))s")

        let idles = [0, 3, 8, 15]
        for arm in arms {
            for idle in idles {
                for run in 1...runs {
                    var warmMs = 0
                    if arm == "tickled" {
                        // The loop as the app runs it: a tickle, then sleep, until the idle is spent.
                        let end = Date().addingTimeInterval(Double(idle))
                        var spent = 0.0
                        repeat {
                            let t0 = Date(); await AICleanup.tickle(); spent += Date().timeIntervalSince(t0)
                            let left = end.timeIntervalSinceNow
                            if left > 0 { try await Task.sleep(nanoseconds: UInt64(min(left, Coordinator.keepWarmInterval) * 1_000_000_000)) }
                        } while Date() < end
                        warmMs = Int(spent * 1000)
                    } else if idle > 0 { try await Task.sleep(nanoseconds: UInt64(idle) * 1_000_000_000) }
                    if arm == "warmed" {
                        let w0 = Date()
                        _ = try? await Coordinator.transcribe(wav: silence)
                        _ = await AICleanup.clean("ok")
                        warmMs = ms(since: w0)
                    }
                    var asrMs = 0
                    var text = raw
                    if arm != "fm-only" {
                        let a0 = Date()
                        text = try await BenchStage.run("recognition \(arm) idle \(idle) run \(run)") { try await Coordinator.transcribe(wav: clip) }
                        asrMs = ms(since: a0)
                    }
                    let c0 = Date()
                    _ = await LocalCleanup.apply(to: text)
                    let cleanMs = ms(since: c0)
                    print("ID|\(arm)|\(idle)|\(run)|\(asrMs)|\(cleanMs)|\(warmMs)")
                }
            }
        }
    }

    private func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }
}
