import XCTest
@testable import Reed

/// Finding 1 of the 2026-08-29 rerun: Parakeet via FluidAudio garbled and
/// truncated the 86 s corpus take ("orthogon"; last 20 s missing) and
/// returned nothing for a 43 s half, while every 20 s window was correct.
/// LongAudioChunker cuts long audio at quiet points first.
final class LongAudioChunkerTests: XCTestCase {
    private let root = VoiceCorpus.root

    /// The voice corpus is gitignored: clean CI runners skip the audio tests.
    private func corpusPCM() throws -> Data {
        guard FileManager.default.fileExists(atPath: "\(root)/clips/clip01.wav") else { throw XCTSkip("no voice corpus on this machine") }
        var pcm = Data()
        for id in (1...10).map({ String(format: "%02d", $0) }) {
            let clip = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips/clip\(id).wav"))
            pcm.append(clip.subdata(in: 44..<clip.count)); pcm.append(Data(count: Int(16_000 * 2 * 0.9)))
        }
        return pcm
    }

    func testShortAudioIsOnePiece() {
        let pcm = Data(count: 10 * 32_000)
        XCTAssertEqual(LongAudioChunker.pieces(pcm: pcm), [LongAudioChunker.Piece(range: 0..<pcm.count, opensAtCapCut: false)])
    }

    func testLongAudioIsCutIntoPiecesUnderTheCap() throws {
        let pcm = try corpusPCM()
        let pieces = LongAudioChunker.pieces(pcm: pcm)
        XCTAssertGreaterThan(pieces.count, 4, "86 s of speech with pauses must cut into several pieces")
        XCTAssertEqual(pieces.first?.range.lowerBound, 0)
        XCTAssertEqual(pieces.last?.range.upperBound, pcm.count)
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            if b.opensAtCapCut {
                // A cap cut pre-rolls: the next piece starts up to 900 ms before the cut.
                XCTAssertLessThanOrEqual(b.range.lowerBound, a.range.upperBound)
                XCTAssertLessThanOrEqual(a.range.upperBound - b.range.lowerBound, SpeechSegmenter.capPreRollMaxMs * SpeechSegmenter.bytesPerMs + 85 * 32)
            } else {
                XCTAssertEqual(a.range.upperBound, b.range.lowerBound, "a pause cut is exact: no gap, no overlap")
            }
        }
        for piece in pieces {
            XCTAssertLessThanOrEqual(Double(piece.range.count) / 32_000, LongAudioChunker.maxSeconds + 1.0, "every piece under the cap (+ pre-roll)")
        }
    }

    /// A no-pause take cuts at the cap and pre-rolls (finding 2).
    func testRunOnCutsPreRoll() throws {
        let path = "\(root)/long_runon.wav"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no run-on input") }
        let wav = try Data(contentsOf: URL(fileURLWithPath: path))
        let pieces = LongAudioChunker.pieces(pcm: wav.subdata(in: 44..<wav.count))
        XCTAssertEqual(pieces.count, 3)
        XCTAssertTrue(pieces.dropFirst().allSatisfy(\.opensAtCapCut))
    }

    /// The regression itself, on the real model (REED_LONG_PROBE=1).
    func testParakeetKeepsEverySentenceOfTheLongTake() async throws {
        guard ProcessInfo.processInfo.environment["REED_LONG_PROBE"] == "1" else { throw XCTSkip("set REED_LONG_PROBE=1") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let pcm = try corpusPCM()
        UserDefaults.standard.set("v3", forKey: ParakeetFlag.key)
        defer { UserDefaults.standard.removeObject(forKey: ParakeetFlag.key) }
        try await ParakeetClient.shared.prepare()
        let text = try await ParakeetClient.shared.transcribe(wav: WAVWriter.wrap(pcm: pcm, sampleRate: 16_000, channels: 1, bitsPerSample: 16))
        print("LP|full|\(text)")
        XCTAssertTrue(text.contains("auth module"), "the sentence that used to garble into 'orthogon'")
        XCTAssertTrue(text.contains("push the branch to GitHub"))
        XCTAssertTrue(text.contains("$20") || text.contains("20 dollars"), "the last 20 s used to be missing")
        // R9: cap seams are joined like the overlapped path — no ". Capital" mid-sentence at a cut.
        XCTAssertFalse(text.contains(". Spend"), "a cap seam must not read as a sentence break")
        XCTAssertFalse(text.contains("orthogon"))
        // Sample-aligned: an odd byte offset misaligns every int16 and the
        // engine returns nothing — that was the probe's bug, not the engine's.
        let half = (pcm.count / 2) & ~1
        let second = try await ParakeetClient.shared.transcribe(wav: WAVWriter.wrap(pcm: pcm.subdata(in: half..<pcm.count), sampleRate: 16_000, channels: 1, bitsPerSample: 16))
        XCTAssertTrue(second.contains("Baker Street"), "a 43 s half must transcribe to its end")
    }
}
