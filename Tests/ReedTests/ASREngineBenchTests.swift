import XCTest
@testable import Reed

/// Lever 3 (2026-08-29): recognition is the largest fixed cost left once
/// cleanup is hidden (step 2) or at its floor (lever 6). Measure the
/// candidate engines on the same clips, same process, same warm state —
/// latency per clip AND the raw text; word error rate against the corpus
/// reference is scored here (BenchScoring, the same arithmetic as
/// scripts/asr_wer.py) and each arm FAILS past its committed ceiling in
/// docs/bench/baselines.json (review 2026-09-01: the ceilings gated only
/// the dashboard, never this bench).
///
/// Gated: REED_ASR_BENCH=1 swift test --filter ASREngineBenchTests
///        REED_ASR_ENGINES=v3,ctc110m (default) · REED_ASR_RUNS=5
/// Lines: AE|<engine>|<clip>|<run>|<ms>|<raw text>
///        AS|score|<engine>|n=<samples>|p50=<ms>|wer=<pct>
final class ASREngineBenchTests: XCTestCase {
    private let root = VoiceCorpus.root

    /// The default engine set: each must have committed WER and p50 lines.
    /// A missing or broken ceilings file fails the bench; only an
    /// experimental engine outside this set may run ungated.
    static let knownEngines: Set<String> = ["v3", "ctc110m"]

    struct Ceilings { let wer: Double?; let p50: Double? }

    /// Resolved BEFORE any model loads: a missing or broken ceilings file
    /// fails in milliseconds, not after minutes of recognition.
    static func ceilings(for engine: String) throws -> Ceilings {
        let known = knownEngines.contains(engine)
        return Ceilings(
            wer: known ? try BenchBaselines.require(["asr", "wer_max_pct", engine]) : try BenchBaselines.ceiling(["asr", "wer_max_pct", engine]),
            p50: known ? try BenchBaselines.require(["asr", "p50_max_ms", engine]) : try BenchBaselines.ceiling(["asr", "p50_max_ms", engine]))
    }

    /// Per-engine verdict against the committed ceilings. WER counts run 1
    /// only (the text does not change between warm runs); latency counts
    /// every run.
    func judge(engine: String, latenciesMs: [Int], errors: Int, words: Int, ceilings: Ceilings) {
        let p50 = BenchScoring.percentile(latenciesMs, 0.5) ?? 0
        let wer = 100.0 * Double(errors) / Double(max(words, 1))
        print("AS|score|\(engine)|n=\(latenciesMs.count)|p50=\(Int(p50))|wer=\(String(format: "%.1f", wer))")
        XCTAssertFalse(latenciesMs.isEmpty, "\(engine): no samples were measured")
        XCTAssertGreaterThan(words, 0, "\(engine): nothing was scored — no run-1 samples met a reference")
        let werCeiling = ceilings.wer, p50Ceiling = ceilings.p50
        if let werCeiling {
            XCTAssertLessThanOrEqual(wer, werCeiling,
                "\(engine) WER \(String(format: "%.1f", wer))% exceeds the committed ceiling \(werCeiling)% (docs/bench/baselines.json)")
        } else { print("AS|note|no committed WER ceiling for experimental engine \(engine) — measured, not gated") }
        if let p50Ceiling {
            XCTAssertLessThanOrEqual(p50, p50Ceiling,
                "\(engine) p50 \(Int(p50)) ms exceeds the committed ceiling \(Int(p50Ceiling)) ms (docs/bench/baselines.json)")
        } else { print("AS|note|no committed p50 ceiling for experimental engine \(engine) — measured, not gated") }
    }

    func testEngines() async throws {
        guard ProcessInfo.processInfo.environment["REED_ASR_BENCH"] == "1" else { throw XCTSkip("set REED_ASR_BENCH=1") }
        // The test process's defaults persist across runs (harness finding 9,
        // 2026-08-29): whatever engine this bench pins must be put back.
        let savedEngineKey = UserDefaults.standard.object(forKey: ParakeetFlag.key)
        defer {
            if let savedEngineKey { UserDefaults.standard.set(savedEngineKey, forKey: ParakeetFlag.key) }
            else { UserDefaults.standard.removeObject(forKey: ParakeetFlag.key) }
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        // Only names the client can actually load, never an empty list, never
        // zero runs (review 2026-09-01): an unknown name loaded v3 under a
        // made-up, ungated label; an empty list measured nothing and passed.
        // "Experimental" means supported but without a committed ceiling
        // (v2) — never "unrecognized".
        let engines = try BenchEnv.list("REED_ASR_ENGINES", default: "v3,ctc110m",
                                        allowed: ParakeetFlag.supportedVariants)
        let runs = try BenchEnv.count("REED_ASR_RUNS", default: 5)
        let clips = try (1...10).map { String(format: "%02d", $0) }.map { id in
            (id, try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips/clip\(id).wav")))
        }
        // Loud, not silent: no reference means no score, and no score must
        // never read as a perfect one.
        let refData = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips_ref.json"))
        let refRows = try XCTUnwrap(try JSONSerialization.jsonObject(with: refData) as? [[String: Any]])
        var references: [String: [String]] = [:]
        for row in refRows {
            guard let id = row["id"] as? String, let verbatim = row["verbatim"] as? String else { continue }
            references[id] = [verbatim, row["clean"] as? String].compactMap { $0 }
        }
        // Identity, not count: ten references for the wrong ids would pass a
        // count check while a clip silently dropped out of the WER.
        XCTAssertEqual(Set(references.keys), Set(clips.map(\.0)), "every clip needs its own reference to be scored")
        var ceilings: [String: Ceilings] = [:]
        for engine in engines { ceilings[engine] = try Self.ceilings(for: engine) }
        print("AE|env|\(ProcessInfo.processInfo.operatingSystemVersionString)")
        for engine in engines {
            var latenciesMs: [Int] = []
            var errors = 0, words = 0
            let engineCeilings = try XCTUnwrap(ceilings[engine])
            UserDefaults.standard.set(engine, forKey: ParakeetFlag.key)
            await ParakeetClient.shared.unload()
            let t0 = Date()
            try await BenchStage.run("parakeet \(engine) prepare") { try await ParakeetClient.shared.prepare() }
            print("AE|load|\(engine)|\(Int(Date().timeIntervalSince(t0) * 1000))")
            let transcribe: (Data) async throws -> String = { try await ParakeetClient.shared.transcribe(wav: $0) }
            // Warm-up, unmeasured.
            _ = try await BenchStage.run("\(engine) warm-up recognition") { try await transcribe(clips[0].1) }
            for (id, wav) in clips {
                for run in 1...runs {
                    let t0 = Date()
                    let text = try await BenchStage.run("\(engine) recognition clip \(id) run \(run)") { try await transcribe(wav) }
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    print("AE|\(engine)|\(id)|\(run)|\(ms)|\(text.replacingOccurrences(of: "\n", with: " "))")
                    latenciesMs.append(ms)
                    if run == 1 {
                        let refs = try XCTUnwrap(references[id], "clip \(id) has no reference — it would drop out of the WER")
                        let score = BenchScoring.bestErrors(hypothesis: text, references: refs)
                        errors += score.errors; words += score.words
                    }
                }
            }
            judge(engine: engine, latenciesMs: latenciesMs, errors: errors, words: words, ceilings: engineCeilings)
        }
        UserDefaults.standard.removeObject(forKey: ParakeetFlag.key)
    }
}
