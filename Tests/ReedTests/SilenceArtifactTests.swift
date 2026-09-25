import XCTest
@testable import Reed

final class SilenceArtifactTests: XCTestCase {
    func testKnownPhraseAtLowRMSIsAnArtifact() {
        XCTAssertTrue(SilenceArtifact.isArtifact("You", rmsDB: -48))
        XCTAssertTrue(SilenceArtifact.isArtifact("Thank you.", rmsDB: -45))
        XCTAssertTrue(SilenceArtifact.isArtifact("Thanks for watching!", rmsDB: -50))
    }

    func testKnownNonSpeechMarkerAtLowRMSIsAnArtifact() {
        // Whisper emits these literal bracketed tokens for a no-speech
        // segment, e.g. pressing the hotkey and saying nothing.
        XCTAssertTrue(SilenceArtifact.isArtifact("[BLANK_AUDIO]", rmsDB: -50))
        XCTAssertTrue(SilenceArtifact.isArtifact("[Music]", rmsDB: -50))
    }

    func testNonSpeechMarkerAtSpeechLevelIsRealDictation() {
        XCTAssertFalse(SilenceArtifact.isArtifact("[BLANK_AUDIO]", rmsDB: -20))
        XCTAssertFalse(SilenceArtifact.isArtifact("[Music]", rmsDB: -20))
    }

    func testBareWordMusicIsNotFilteredAsMarker() {
        // Markers are matched exactly, not through normalize() — saying
        // the bare word "Music" is real dictation, not the model's tag.
        XCTAssertFalse(SilenceArtifact.isArtifact("Music", rmsDB: -50))
        XCTAssertFalse(SilenceArtifact.isArtifact("music", rmsDB: -50))
    }

    func testNonSpeechMarkerCaseMustMatchExactly() {
        XCTAssertFalse(SilenceArtifact.isArtifact("[blank_audio]", rmsDB: -50))
        XCTAssertFalse(SilenceArtifact.isArtifact("[MUSIC]", rmsDB: -50))
    }

    func testSamePhraseAtSpeechLevelIsRealDictation() {
        XCTAssertFalse(SilenceArtifact.isArtifact("Thank you.", rmsDB: -20))
        XCTAssertFalse(SilenceArtifact.isArtifact("You", rmsDB: -25))
    }

    func testUnknownContentIsNeverFilteredEvenWhenQuiet() {
        XCTAssertFalse(SilenceArtifact.isArtifact("Buy milk", rmsDB: -50))
        XCTAssertFalse(SilenceArtifact.isArtifact("Ship it tomorrow", rmsDB: -48))
    }

    func testRMSThresholdBoundaryIsStrict() {
        // The −36 dB line encodes an accepted product trade-off; the guard
        // is strictly-below, so exactly at the threshold is real dictation.
        XCTAssertFalse(SilenceArtifact.isArtifact("You", rmsDB: SilenceArtifact.maxPlausibleRMSdB))
        XCTAssertTrue(SilenceArtifact.isArtifact("You", rmsDB: SilenceArtifact.maxPlausibleRMSdB - 0.01))
    }

    func testUnknownTokenMarkersAreStripped() {
        // Field 2026-08-19: Parakeet typed five "<unk>" markers into a doc.
        XCTAssertEqual(
            SilenceArtifact.strippingUnknownTokens("<Unk> <unk> Example <unk> com."),
            "Example com.")
        XCTAssertEqual(
            SilenceArtifact.strippingUnknownTokens("<unk> <unk> <unk>"), "")
        XCTAssertEqual(
            SilenceArtifact.strippingUnknownTokens("perfectly normal text"),
            "perfectly normal text")
    }

}
