import XCTest
@testable import Reed

final class DenoiserTests: XCTestCase {
    private func silentWAV() -> Data {
        WAVWriter.wrap(pcm: Data(repeating: 0, count: 320), sampleRate: 16_000, channels: 1, bitsPerSample: 16)
    }

    func testFallsBackWhenModelURLIsNil() async {
        let denoiser = Denoiser(modelURLProvider: { nil })
        let wav = silentWAV()
        let out = await denoiser.process(wav: wav)
        XCTAssertEqual(out, wav)
    }

    func testFallsBackWhenModelURLDoesNotExist() async {
        let denoiser = Denoiser(modelURLProvider: { URL(fileURLWithPath: "/nonexistent/model.onnx") })
        let wav = silentWAV()
        let out = await denoiser.process(wav: wav)
        XCTAssertEqual(out, wav)
    }

    func testFallsBackOnEmptyWAV() async {
        let denoiser = Denoiser(modelURLProvider: { DenoiserModelTests.modelURL })
        let out = await denoiser.process(wav: Data())
        XCTAssertEqual(out, Data())
    }

    func testProcessesRealModelAndPreservesWAVSize() async throws {
        let denoiser = Denoiser(modelURLProvider: { DenoiserModelTests.modelURL })
        let sampleCount = 8_000 // 0.5s @ 16kHz
        var pcm = Data(capacity: sampleCount * 2)
        for i in 0..<sampleCount {
            var le = Int16(sin(Double(i) / 20) * 8_000).littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        let wav = WAVWriter.wrap(pcm: pcm, sampleRate: 16_000, channels: 1, bitsPerSample: 16)

        let out = await denoiser.process(wav: wav)

        XCTAssertEqual(out.count, wav.count, "denoised WAV must carry the same sample count as the input")
        XCTAssertNotEqual(out, wav, "a real model run should change the sample bytes")
    }

    func testDoesNotTouchNetwork() async throws {
        NetworkGate.shared.activity.reset()
        let denoiser = Denoiser(modelURLProvider: { DenoiserModelTests.modelURL })
        _ = await denoiser.process(wav: silentWAV())
        XCTAssertEqual(NetworkGate.shared.activity.blockedCount, 0)
    }
}
