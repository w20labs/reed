import XCTest
@testable import Reed

/// Review 2026-09-03 (P2): a prepare suspended in the load when an
/// `unload()` lands must commit nothing — an unload racing a load (the
/// benches unload between engines) used to end with the model resident and
/// "ready" again. Exercised through the
/// client's test seam, which lands the unload in the exact window between
/// the load and the commit. Proven non-vacuous: with the fix disabled
/// (generation guard + `unload()`'s cancel) the test fails as the reviewer
/// described. (The WhisperKit twin left with the engine, 2026-09-06.)
final class EngineUnloadRaceTests: XCTestCase {
    override func tearDown() {
        ParakeetClient.afterLoadForTests = nil
        super.tearDown()
    }

    /// Runs the REAL Parakeet load (skips on a machine without the model,
    /// i.e. CI).
    @MainActor
    func testParakeetUnloadDuringTheLoadWinsAndNothingIsCommitted() async throws {
        try XCTSkipUnless(ModelStore.isSpeechModelInstalled, "needs the speech model on disk")
        await ParakeetClient.shared.unload()
        XCTAssertFalse(ParakeetClient.isReady)

        // The mode switch lands while the load is suspended.
        ParakeetClient.afterLoadForTests = { await ParakeetClient.shared.unload() }
        do {
            try await ParakeetClient.shared.prepare()
            XCTFail("a load overtaken by an unload must not report success")
        } catch is CancellationError {
            // expected: commit refused
        }
        XCTAssertFalse(ParakeetClient.isReady, "the overtaken load must not leave the model resident")

        // Without the interleaved unload the same load commits normally.
        ParakeetClient.afterLoadForTests = nil
        try await ParakeetClient.shared.prepare()
        XCTAssertTrue(ParakeetClient.isReady)
        await ParakeetClient.shared.unload()
    }

    /// Review 2026-09-04 (P2): `prepare()` runs its work in an inner task
    /// that does not inherit the caller's cancellation, so a caller retired
    /// before it got here (a mode store task cancelled by the next switch)
    /// used to start a load nobody wanted. The client refuses at the door.
    @MainActor
    func testParakeetPrepareFromARetiredCallerStartsNothing() async throws {
        try XCTSkipUnless(ModelStore.isSpeechModelInstalled, "needs the speech model on disk")
        await ParakeetClient.shared.unload()
        let caller = Task { @MainActor in
            do {
                try await ParakeetClient.shared.prepare()
                XCTFail("a retired caller must not get a load")
            } catch is CancellationError {
                // expected
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }
        caller.cancel()  // before it runs: the test holds the main actor
        await caller.value
        XCTAssertFalse(ParakeetClient.isReady, "a retired caller must not leave the model resident")
    }
}
