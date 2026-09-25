import XCTest
@testable import Reed

/// The WAV header feeds every transcription; a wrong field degrades ASR
/// silently, so the byte layout is pinned.
final class WAVWriterTests: XCTestCase {
    func testHeaderMathFor16kMono16Bit() {
        let pcm = Data(repeating: 0xAB, count: 100)
        let wav = WAVWriter.wrap(pcm: pcm, sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        XCTAssertEqual(wav.count, 144)                                   // 44-byte header + data
        XCTAssertEqual(ascii(wav, 0..<4), "RIFF")
        XCTAssertEqual(le32(wav, 4), 136)                                // 36 + data size
        XCTAssertEqual(ascii(wav, 8..<12), "WAVE")
        XCTAssertEqual(ascii(wav, 12..<16), "fmt ")
        XCTAssertEqual(le32(wav, 16), 16)                                // fmt chunk size
        XCTAssertEqual(le16(wav, 20), 1)                                 // PCM
        XCTAssertEqual(le16(wav, 22), 1)                                 // mono
        XCTAssertEqual(le32(wav, 24), 16_000)                            // sample rate
        XCTAssertEqual(le32(wav, 28), 32_000)                            // byte rate
        XCTAssertEqual(le16(wav, 32), 2)                                 // block align
        XCTAssertEqual(le16(wav, 34), 16)                                // bits/sample
        XCTAssertEqual(ascii(wav, 36..<40), "data")
        XCTAssertEqual(le32(wav, 40), 100)
        XCTAssertEqual(wav[44...], pcm)
    }

    func testStereoByteRateAndBlockAlign() {
        let wav = WAVWriter.wrap(pcm: Data(), sampleRate: 44_100, channels: 2, bitsPerSample: 16)
        XCTAssertEqual(le32(wav, 28), 176_400)
        XCTAssertEqual(le16(wav, 32), 4)
        XCTAssertEqual(le32(wav, 40), 0)
        XCTAssertEqual(wav.count, 44)
    }

    private func ascii(_ data: Data, _ range: Range<Int>) -> String? {
        String(data: data[range], encoding: .ascii)
    }

    private func le16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
