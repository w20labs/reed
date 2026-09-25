import Darwin
import XCTest
@testable import Reed

/// Phase 1 of the cleanup-latency study (spec 2026-08-27, "Instrument before
/// optimizing"): where does on-device latency actually go? Runs the SHIPPED
/// pipeline stage by stage over the voice-test clips — denoise → ASR →
/// sentence split → vocabulary pass → per-chunk Foundation Models cleanup →
/// the real composite (`LocalCleanup.applyWithPath`) — warm models, N runs,
/// with resident memory + thermal state per sample. Ships nothing; measures.
///
/// Gated: REED_P1_BENCH=1 swift test --filter Phase1LatencyBenchTests
///        REED_P1_RUNS=10 (default) · REED_VOICE_ROOT=<corpus> · REED_P1_COALESCE=0|1
///
/// Output lines (parsed by scripts/analyze_p1.py):
///   P1|env|<macOS>|<thermal>|coalesce=<bool>
///   P1|load|<ms>                               warm speech-model load
///   P1|denoise|<run>|<clip>|<ms>
///   P1|asr|<run>|<clip>|<ms>|<audio_s>|<chars>
///   P1|split|<run>|<clip>|<ms>|<chunks>
///   P1|vocab|<run>|<clip>|<ms>
///   P1|ai|<run>|<clip>|<chunk>|<ms>|<in_chars>|<out_chars>|<repair>|<accepted>
///   P1|cleanup|<run>|<clip>|<ms>|<path>|<reason>|<text>   the shipped composite
///   P1|e2e|<run>|<clip>|<ms>                       denoise+asr+vocab+cleanup
///   P1|mem|<run>|<clip>|<rss_mb>|<thermal>
///
/// Excluded from e2e, deliberately: recorder stop/flush and text injection —
/// both are single-digit-ms and independent of the question under test.
/// `ai` lines re-run the model per chunk OUTSIDE the composite so the LLM
/// stage can be read on its own; `cleanup` is the number the user feels.
final class Phase1LatencyBenchTests: XCTestCase {
    /// The shipped engines: each must have a committed p95 line.
    static let knownArms: Set<String> = ["v3"]
    private let root = VoiceCorpus.root

    func testPhase1Latency() async throws {
        guard ProcessInfo.processInfo.environment["REED_P1_BENCH"] == "1" else {
            throw XCTSkip("set REED_P1_BENCH=1 to run (loads on-device models)")
        }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else {
            throw XCTSkip("Apple Foundation Models unavailable — the cleanup stage cannot be measured")
        }
        // Line-buffered stdout: `swift test` block-buffers when piped, and
        // xctest's own "Test Case … passed" line then lands INSIDE a buffered
        // data line, corrupting it (lost 4 of 10 lines on 2026-08-27).
        // The test process's defaults persist across runs (harness finding 9,
        // 2026-08-29): whatever engine this bench pins must be put back.
        let savedEngineKey = UserDefaults.standard.object(forKey: ParakeetFlag.key)
        defer {
            if let savedEngineKey { UserDefaults.standard.set(savedEngineKey, forKey: ParakeetFlag.key) }
            else { UserDefaults.standard.removeObject(forKey: ParakeetFlag.key) }
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let clips = try loadClips()
        XCTAssertEqual(clips.count, 10)
        // REED_P1_COALESCE=0|1 pins the sentence-coalescing flag for THIS
        // process via the same local-override key the app honours (the test
        // process has its own defaults domain, so `defaults write` on the
        // app's domain wouldn't reach it). Unset = the shipped default.
        // Cleared afterwards.
        let overrideKey = FeatureFlags.overrideKey(for: LocalCleanup.coalesceFlag)
        if let pin = ProcessInfo.processInfo.environment["REED_P1_COALESCE"] {
            UserDefaults.standard.set(pin == "1", forKey: overrideKey)
        }
        defer { UserDefaults.standard.removeObject(forKey: overrideKey) }
        // Mirror the shipped routing: the composite reads the remote flag (or
        // its local override); the per-chunk lines must chunk the same way.
        // REED_P1_PARAKEET=v3|v2|ctc110m|off pins the recognition engine;
        // unset = the app's default (Parakeet v3 since 2026-08-29).
        if let variant = ProcessInfo.processInfo.environment["REED_P1_PARAKEET"] {
            // Only a variant the client can load (review 2026-09-01): an
            // unknown name loaded v3 under a made-up, ungated label.
            let allowed = ParakeetFlag.supportedVariants
            guard allowed.contains(variant) else {
                XCTFail("REED_P1_PARAKEET='\(variant)' is not an engine (allowed: \(allowed.sorted().joined(separator: ", ")))")
                return
            }
            UserDefaults.standard.set(variant, forKey: ParakeetFlag.key)
        } else {
            UserDefaults.standard.removeObject(forKey: ParakeetFlag.key)
        }
        // The ceiling resolves BEFORE any model loads: a missing or broken
        // ceilings file fails in milliseconds, not after minutes of work.
        // The shipped arms MUST have a line; experimental arms may run
        // ungated (and say so). The arm is the engine that actually runs —
        // the same value the env line carries and the QA page reads.
        let arm = ParakeetFlag.variant
        let runs = try BenchEnv.count("REED_P1_RUNS", default: 10)  // positive, or the bench fails here, before any model loads
        let ceiling = Self.knownArms.contains(arm)
            ? try BenchBaselines.require(["p1", "e2e_p95_ms", arm])
            : try BenchBaselines.ceiling(["p1", "e2e_p95_ms", arm])
        let coalesce = await MainActor.run {
            FeatureFlags.shared.isEnabled(LocalCleanup.coalesceFlag, default: true)
        }
        print("P1|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|\(thermal())|coalesce=\(coalesce)|engine=\(ParakeetFlag.variant)")

        // Warm speech model (the shipped state).
        let tLoad = Date()
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        print("P1|load|\(ms(since: tLoad))")

        // Shipped cleanup tier for the composite; restored afterwards.
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
        defer {
            if let savedTier {
                UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey)
            }
        }

        // Denoise, proven to run (review 2026-09-08): the bench used to
        // measure raw audio silently when no bundle held the model.
        try await BenchDenoise.require()
        // Warm-up pass (unmeasured): model asset loads, session prewarm, caches.
        AICleanup.prewarm()
        for (_, wav) in clips.sorted(by: { $0.key < $1.key }) {
            let text = try await BenchStage.run("warm-up recognition") { try await Coordinator.transcribe(wav: await Denoiser.shared.process(wav: wav)) }
            _ = await LocalCleanup.applyWithPath(to: text)
        }

        var e2eSamples: [Int] = []
        for run in 1...runs {
            for (id, wav) in clips.sorted(by: { $0.key < $1.key }) {
                let t0 = Date()
                let (denoised, denoiseOutcome) = await Denoiser.shared.processReporting(wav: wav)
                BenchDenoise.assertProcessed(denoiseOutcome, "run \(run) clip \(id)")
                let denoiseMs = ms(since: t0)
                print("P1|denoise|\(run)|\(id)|\(denoiseMs)")

                let t1 = Date()
                let raw = try await BenchStage.run("recognition run \(run) clip \(id)") { try await Coordinator.transcribe(wav: denoised) }
                let asrMs = ms(since: t1)
                let audioSeconds = Double(max(0, denoised.count - 44)) / 32_000
                print("P1|asr|\(run)|\(id)|\(asrMs)|\(String(format: "%.1f", audioSeconds))|\(raw.count)")

                let t2 = Date()
                let corrected = CorrectionSession().apply(raw).text
                let vocabMs = ms(since: t2)
                print("P1|vocab|\(run)|\(id)|\(vocabMs)")

                let t3 = Date()
                let chunks = SentenceChunker.split(corrected, coalesce: coalesce, glueFragments: true)
                print("P1|split|\(run)|\(id)|\(ms(since: t3))|\(chunks.count)")

                // The LLM stage on its own, per chunk, with the shipped
                // acceptance nets so "accepted" is the real routing outcome.
                for (index, chunk) in chunks.enumerated() {
                    let repair = LocalCleanup.structuralReason(chunk) != nil
                    let t4 = Date()
                    let out = await AICleanup.clean(chunk, repair: repair).text
                    let aiMs = ms(since: t4)
                    let accepted: Bool
                    if let out, !out.isEmpty,
                       LocalCleanup.looksFaithful(input: chunk, output: out, minRecall: 0.5, maxGrowth: 3),
                       CleanupGate.accepts(input: chunk, output: out, repairHint: repair) {
                        accepted = true
                    } else {
                        accepted = false
                    }
                    print("P1|ai|\(run)|\(id)|\(index)|\(aiMs)|\(chunk.count)|\(out?.count ?? 0)|\(repair)|\(accepted)")
                }

                // The shipped composite — what the user actually waits for.
                let t5 = Date()
                let outcome = await LocalCleanup.applyWithPath(to: corrected)
                let cleanupMs = ms(since: t5)
                // Output text rides the line (one-line) so a before/after run
                // can be diffed for quality, not just timed.
                print("P1|cleanup|\(run)|\(id)|\(cleanupMs)|\(outcome.path.rawValue)|\(outcome.reason ?? "-")|\(outcome.text.replacingOccurrences(of: "\n", with: " ⏎ "))")

                let e2eMs = denoiseMs + asrMs + vocabMs + cleanupMs
                e2eSamples.append(e2eMs)
                print("P1|e2e|\(run)|\(id)|\(e2eMs)")
                print("P1|mem|\(run)|\(id)|\(residentMB())|\(thermal())")
            }
        }

        // Regression ceiling (audit 2026-08-30): the bench FAILS, not warns,
        // when the p95 the user waits for regresses past the committed line.
        // p95 by the scripts' interpolation, so bench and page agree
        // (review 2026-09-01); the ceiling was resolved up top.
        let p95 = try XCTUnwrap(BenchScoring.percentile(e2eSamples, 0.95), "no e2e samples were measured")
        if let ceiling {
            XCTAssertLessThanOrEqual(p95, ceiling,
                "e2e p95 \(Int(p95)) ms exceeds the committed \(arm) ceiling \(Int(ceiling)) ms (docs/bench/baselines.json)")
        } else {
            print("P1|note|no committed ceiling for experimental arm \(arm) — measured, not gated")
        }
    }

    // MARK: helpers

    private func loadClips() throws -> [String: Data] {
        var out: [String: Data] = [:]
        for id in (1...10).map({ String(format: "%02d", $0) }) {
            out[id] = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips/clip\(id).wav"))
        }
        return out
    }

    private func ms(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    private func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Physical footprint (what Activity Monitor calls Memory), in MB.
    private func residentMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
