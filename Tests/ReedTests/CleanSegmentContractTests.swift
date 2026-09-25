import XCTest
@testable import Reed

/// The overlap design's core contract (audit gap 3, 2026-08-30), pinned via
/// the transcribe seam: a segment that hears nothing contributes `""` —
/// which costs the press nothing — while a segment that FAILS returns nil,
/// which makes the whole press fall back to single-pass. Confusing the two
/// either drops user words or spends a fallback on silence. Plus the
/// `armOverlapIfEnabled` eligibility gate (a wrong branch strands
/// segmenting across presses).
@MainActor
final class CleanSegmentContractTests: XCTestCase {
    private var coordinator: Coordinator!
    private var savedOnboarding: Any?
    private let wav = WAVWriter.wrap(pcm: Data(count: 3_200), sampleRate: 16_000, channels: 1, bitsPerSample: 16)

    override func setUp() {
        super.setUp()
        savedOnboarding = UserDefaults.standard.object(forKey: OnboardingState.completedKey)
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
        coordinator = Coordinator()
    }

    override func tearDown() {
        Coordinator.transcribeOverride = nil
        if let savedOnboarding { UserDefaults.standard.set(savedOnboarding, forKey: OnboardingState.completedKey) }
        else { UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey) }
        UserDefaults.standard.removeObject(forKey: FeatureFlags.overrideKey(for: Coordinator.overlapFlag))
        super.tearDown()
    }

    func testARecognizedSegmentComesBackAsText() async {
        Coordinator.transcribeOverride = { _ in "hello from the segment" }
        let text = await coordinator.cleanSegment(wav: wav, rmsDB: -20)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.lowercased().contains("hello") == true)
    }

    func testASilentSegmentContributesEmptyNotFailure() async {
        Coordinator.transcribeOverride = { _ in "   \n" }
        let text = await coordinator.cleanSegment(wav: wav, rmsDB: -20)
        XCTAssertEqual(text, "", "silence costs the press nothing — it must not trigger fallback")
    }

    func testAQuietArtifactContributesEmptyNotFailure() async {
        Coordinator.transcribeOverride = { _ in "Thank you." }
        let text = await coordinator.cleanSegment(wav: wav, rmsDB: -45)
        XCTAssertEqual(text, "", "a hallucinated artifact on a quiet segment is not user speech")
    }

    func testTheSameArtifactTextOnALoudSegmentIsKept() async {
        Coordinator.transcribeOverride = { _ in "Thank you." }
        let text = await coordinator.cleanSegment(wav: wav, rmsDB: -15)
        XCTAssertNotEqual(text, "", "at speech loudness the user really said it")
        XCTAssertNotNil(text)
    }

    func testAFailedSegmentIsNilSoThePressFallsBack() async {
        struct EngineDown: Error {}
        Coordinator.transcribeOverride = { _ in throw EngineDown() }
        let text = await coordinator.cleanSegment(wav: wav, rmsDB: -20)
        XCTAssertNil(text, "a real failure must surface as nil → single-pass fallback")
    }

    /// The kill switch must disarm BOTH sides — an armed recorder with a
    /// disarmed session is exactly the stranded state that leaked text
    /// between presses.
    func testOverlapFlagOffDisarmsRecorderAndSession() {
        coordinator.overlap.arm()
        coordinator.recorder.bufferQueue.sync { coordinator.recorder.segmentingEnabled = true }
        UserDefaults.standard.set(false, forKey: FeatureFlags.overrideKey(for: Coordinator.overlapFlag))
        coordinator.armOverlapIfEnabled()
        XCTAssertFalse(coordinator.overlap.isArmed)
        coordinator.recorder.bufferQueue.sync {
            XCTAssertFalse(coordinator.recorder.segmentingEnabled)
        }
    }

    func testEligiblePressArmsBothSides() throws {
        // Overlap arms only once the engine is LOADED (review 2026-09-03):
        // on disk is not enough, so this case needs a warm Parakeet.
        try XCTSkipUnless(ParakeetClient.isReady, "needs the speech model loaded, not just installed")
        coordinator.armOverlapIfEnabled()
        XCTAssertTrue(coordinator.overlap.isArmed)
        coordinator.recorder.bufferQueue.sync {
            XCTAssertTrue(coordinator.recorder.segmentingEnabled)
        }
        coordinator.disarmOverlap()
    }
}
