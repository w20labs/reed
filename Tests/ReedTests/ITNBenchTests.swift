import XCTest
@testable import Reed

/// Finding 3 (2026-08-29): how spoken numbers, dates, times, phone numbers,
/// versions and ordinals come out of the pipeline today — raw recognizer,
/// after the vocabulary/spoken-forms pass, after cleanup — per engine.
///
/// Gated: REED_ITN_BENCH=1 swift test --filter ITNBenchTests   (REED_ITN_ENGINES=v3,ctc110m)
/// Lines: NB|<id>|<engine>|<raw>|<vocab>|<clean>|<reference>
final class ITNBenchTests: XCTestCase {
    private let root = VoiceCorpus.root

    @MainActor
    func testNumbersThroughThePipeline() async throws {
        guard ProcessInfo.processInfo.environment["REED_ITN_BENCH"] == "1" else { throw XCTSkip("set REED_ITN_BENCH=1") }
        // The test process's defaults persist across runs (harness finding 9,
        // 2026-08-29): whatever engine this bench pins must be put back.
        let savedEngineKey = UserDefaults.standard.object(forKey: ParakeetFlag.key)
        defer {
            if let savedEngineKey { UserDefaults.standard.set(savedEngineKey, forKey: ParakeetFlag.key) }
            else { UserDefaults.standard.removeObject(forKey: ParakeetFlag.key) }
        }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else {
            throw XCTSkip("no Foundation Models — rules-only output must not be reported as pipeline output")
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let savedOnboarding = UserDefaults.standard.object(forKey: OnboardingState.completedKey)
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        defer {
            if let savedOnboarding { UserDefaults.standard.set(savedOnboarding, forKey: OnboardingState.completedKey) }
            else { UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey) }
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/numbers/numbers_ref.json"))
        let cases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
        UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
        let coordinator = Coordinator()
        // Only a variant the client can load, never an empty list (review
        // 2026-09-01): an unknown name loaded v3 and labelled every NB line
        // with it; an empty list measured nothing and passed.
        let engines = try BenchEnv.list("REED_ITN_ENGINES", default: "v3",
                                        allowed: ParakeetFlag.supportedVariants)
        XCTAssertFalse(cases.isEmpty, "numbers_ref.json holds no cases — nothing would be measured")
        for engine in engines {
            UserDefaults.standard.set(engine, forKey: ParakeetFlag.key)
            await ParakeetClient.shared.unload()
            try await BenchStage.run("parakeet \(engine) prepare") { try await ParakeetClient.shared.prepare() }
            for c in cases {
                guard let id = c["id"] as? String, let ref = c["clean"] as? String else {
                    XCTFail("numbers_ref.json case without id/clean would silently drop out: \(c)"); continue
                }
                let wav = try Data(contentsOf: URL(fileURLWithPath: "\(root)/numbers/\(id).wav"))
                let raw = try await BenchStage.run("recognition \(engine) case \(id)") { try await Coordinator.transcribe(wav: wav) }
                let vocab = coordinator.applyVocabCorrections(to: raw)
                let clean = await LocalCleanup.apply(to: vocab)
                print("NB|\(id)|\(engine)|\(raw)|\(vocab)|\(clean)|\(ref)")
            }
        }
        UserDefaults.standard.removeObject(forKey: ParakeetFlag.key)
    }
}
