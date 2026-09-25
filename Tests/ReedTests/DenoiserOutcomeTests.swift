import XCTest
@testable import Reed

/// The denoiser says what it did (review 2026-09-08): the app never fails
/// on denoise, but a bench must not measure raw audio without knowing.
final class DenoiserOutcomeTests: XCTestCase {
    override func tearDown() {
        Denoiser.modelURLOverrideForTests = nil
        Denoiser.outcomeObserverForTests = nil
        DenoiseWatchdog.shared.resetForTests()
        super.tearDown()
    }

    /// Every outcome reaches the observer — a direct call's, and the
    /// coordinator stage's watchdog bypass and deadline, which return raw
    /// audio with no call at all (review 2026-09-08).
    @MainActor
    func testTheObserverSeesDirectFaultsAndTheStagesBypasses() async {
        var seen: [Denoiser.Outcome] = []
        Denoiser.outcomeObserverForTests = { outcome in Task { @MainActor in seen.append(outcome) } }
        let bogus = FileManager.default.temporaryDirectory.appending(path: "not-a-model-\(UUID().uuidString).onnx")
        try? Data("nope".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        _ = await Denoiser(modelURLProvider: { bogus }).processReporting(wav: BenchReplay.wrap(Data(repeating: 0x22, count: 16_000)))
        _ = await Denoiser(modelURLProvider: { nil }).process(wav: BenchReplay.wrap(Data(repeating: 0x22, count: 16_000)))
        let coordinator = BenchReplay.makeCoordinator()
        DenoiseWatchdog.shared.markWedged()
        _ = await coordinator.denoiseStage(BenchReplay.wrap(Data(repeating: 0x22, count: 16_000)))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(seen, [.loadFailed, .noModel, .watchdogBypassed])
    }

    func testNoModelIsReportedAndSticksForTheSession() async {
        let denoiser = Denoiser(modelURLProvider: { nil })
        let wav = BenchReplay.wrap(Data(repeating: 0x22, count: 16_000))
        let first = await denoiser.processReporting(wav: wav)
        XCTAssertEqual(first.outcome, .noModel)
        XCTAssertEqual(first.audio, wav, "raw audio passed on")
        let second = await denoiser.processReporting(wav: wav)
        XCTAssertEqual(second.outcome, .noModel, "disabled for the session, still reported")
    }

    func testALoadFailureIsReported() async {
        let bogus = FileManager.default.temporaryDirectory.appending(path: "not-a-model-\(UUID().uuidString).onnx")
        try? Data("nope".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        let denoiser = Denoiser(modelURLProvider: { bogus })
        let outcome = await denoiser.processReporting(wav: BenchReplay.wrap(Data(repeating: 0x22, count: 16_000))).outcome
        XCTAssertEqual(outcome, .loadFailed)
    }

    func testTheRepoModelProcessesSpeechAndSkipsSilence() async throws {
        let url = BenchDenoise.modelURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "model not in this checkout")
        let denoiser = Denoiser(modelURLProvider: { url })
        var seed: UInt32 = 5
        let speech: [Int16] = (0..<16_000).map { _ in seed = seed &* 1_664_525 &+ 1_013_904_223; return Int16(truncatingIfNeeded: Int(seed >> 16) % 8_001 - 4_000) }
        let processed = await denoiser.processReporting(wav: BenchReplay.wrap(speech.withUnsafeBufferPointer { Data(buffer: $0) }))
        XCTAssertEqual(processed.outcome, .processed)
        XCTAssertEqual(processed.audio.count, 44 + 32_000, "the same length back")
        let silence = await denoiser.processReporting(wav: BenchReplay.wrap(Data(count: 32_000))).outcome
        XCTAssertEqual(silence, .skippedSilence)
        let empty = await denoiser.processReporting(wav: BenchReplay.wrap(Data())).outcome
        XCTAssertEqual(empty, .emptyAudio)
        let plain = await denoiser.process(wav: BenchReplay.wrap(Data(count: 32_000)))
        XCTAssertEqual(plain, BenchReplay.wrap(Data(count: 32_000)), "process(wav:) is the audio of processReporting")
    }

    func testTheSharedSeamIsNilInProductionAndTheHelperProvesARun() async throws {
        XCTAssertNil(Denoiser.modelURLOverrideForTests)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: BenchDenoise.modelURL.path), "model not in this checkout")
        try await BenchDenoise.require()
        XCTAssertEqual(Denoiser.modelURLOverrideForTests, BenchDenoise.modelURL)
    }
}
