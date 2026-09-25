import XCTest
@testable import Reed

/// The second-reading policy on a scripted recognizer: selection, limits,
/// verbatim strings, failure handling, and the flag — the production path
/// through `ParakeetClient.transcribe` with the model call replaced.
final class SecondReadingTests: XCTestCase {
    override func tearDown() {
        ParakeetClient.recognizerOverride = nil
        SecondReading.selectionObserver = nil
        UserDefaults.standard.removeObject(forKey: FeatureFlags.overrideKey(for: SecondReading.flag))
        super.tearDown()
    }

    func testTheSecondReadingReplacesOnlyACollapse() {
        XCTAssertEqual(SecondReading.select(original: "", alternate: "he will be allowed to").replaced, true)
        XCTAssertEqual(SecondReading.select(original: "API key.", alternate: "Um, API key, which model did you use?").replaced, true, "2 vs 7")
        XCTAssertEqual(SecondReading.select(original: "Yes.", alternate: "Yes, please, now.").replaced, true, "1 vs 3: the smallest replacement")
        XCTAssertEqual(SecondReading.select(original: "Yes.", alternate: "Yes please.").replaced, false, "1 vs 2: a short command stays")
        XCTAssertEqual(SecondReading.select(original: "Ship it.", alternate: "Ship it now.").replaced, false, "2 vs 3: not twice as long")
        XCTAssertEqual(SecondReading.select(original: "Ship it now.", alternate: "Ship it now, Dana, please.").replaced, false, "3 vs 5: healthy variance")
        XCTAssertEqual(SecondReading.select(original: "", alternate: "Thank you.").replaced, false, "0 vs 2: under the minimum")
        XCTAssertEqual(SecondReading.select(original: "", alternate: "").replaced, false)
        XCTAssertEqual(SecondReading.select(original: "Hello.", alternate: nil).replaced, false)
    }

    func testTheSelectedStringIsVerbatimAndWordsAreCountedNotChanged() {
        let kept = SecondReading.select(original: "Hello, World. It's 5 o'clock!", alternate: "Hello, World. It's 5 o'clock!")
        XCTAssertEqual(kept.text, "Hello, World. It's 5 o'clock!")
        XCTAssertEqual(kept.originalWords, 5)
        let replaced = SecondReading.select(original: "", alternate: "Ship it, Dana. IT can deploy.")
        XCTAssertEqual(replaced.text, "Ship it, Dana. IT can deploy.", "punctuation and case survive selection")
        XCTAssertEqual(SecondReading.wordCount("don’t re-run it"), 4)
    }

    func testThePrefixIsFortyMillisecondsOfQuietDeterministicNoise() {
        XCTAssertEqual(SecondReading.prefix.count, 40 * 32)
        XCTAssertEqual(SecondReading.prefix, SecondReading.prefix)
        let level = RecordingLevels.measure(pcm: SecondReading.prefix)
        XCTAssertLessThan(level.rmsDB, -55)
        XCTAssertGreaterThan(level.rmsDB, -70)
    }

    /// Through `read`: one call with the flag off, two at most with it on,
    /// the second on the prefixed bytes; the original's failure propagates,
    /// the alternate's is ignored.
    func testReadMakesAtMostTwoCallsAndHandlesFailures() async throws {
        let pcm = Data(repeating: 0x11, count: 3_200)
        let calls = Calls()
        let off = try await SecondReading.read(pcm, enabled: false) { data in await calls.note(data); return "As cut." }
        XCTAssertEqual(off, .init(text: "As cut.", replaced: false, originalWords: 2, alternateWords: nil))
        let offCalls = await calls.seen
        XCTAssertEqual(offCalls, [pcm], "flag off: exactly one call, the slice as cut")
        await calls.reset()
        let on = try await SecondReading.read(pcm, enabled: true) { data in await calls.note(data); return data == pcm ? "" : "He will be allowed to." }
        XCTAssertEqual(on.text, "He will be allowed to.")
        XCTAssertTrue(on.replaced)
        let onCalls = await calls.seen
        XCTAssertEqual(onCalls, [pcm, SecondReading.prefix + pcm], "the second call is the prefix and then the same bytes: nothing discarded")
        struct Boom: Error {}
        let alternateFailed = try await SecondReading.read(pcm, enabled: true) { data in if data != pcm { throw Boom() }; return "Kept." }
        XCTAssertEqual(alternateFailed, .init(text: "Kept.", replaced: false, originalWords: 1, alternateWords: nil))
        do {
            _ = try await SecondReading.read(pcm, enabled: true) { _ in throw Boom() }
            XCTFail("the first reading's failure must propagate")
        } catch is Boom {}
    }

    /// The production path: `ParakeetClient.transcribe` with the model call
    /// scripted. Flag off is byte-for-byte today's behaviour.
    func testTheClientAppliesThePolicyAndTheFlagOffIsTodaysPath() async throws {
        let wav = BenchReplay.wrap(Data(repeating: 0x22, count: 16_000))
        let calls = Calls()
        ParakeetClient.recognizerOverride = { data in await calls.note(data); return data.count == 16_000 ? "Hello." : "Hello, this is the second reading." }
        UserDefaults.standard.set(false, forKey: FeatureFlags.overrideKey(for: SecondReading.flag))
        let off = try await ParakeetClient.shared.transcribe(wav: wav)
        XCTAssertEqual(off, "Hello.")
        let offCalls = await calls.seen.count
        XCTAssertEqual(offCalls, 1)
        await calls.reset()
        UserDefaults.standard.set(true, forKey: FeatureFlags.overrideKey(for: SecondReading.flag))
        let on = try await ParakeetClient.shared.transcribe(wav: wav)
        XCTAssertEqual(on, "Hello, this is the second reading.", "1 vs 6 words: a collapse, replaced verbatim")
        let onCalls = await calls.seen
        XCTAssertEqual(onCalls.count, 2)
        XCTAssertEqual(onCalls.last?.prefix(SecondReading.prefix.count), SecondReading.prefix)
        await calls.reset()
        ParakeetClient.recognizerOverride = { data in await calls.note(data); return data.count == 16_000 ? "Ship it." : "Ship it now." }
        let healthy = try await ParakeetClient.shared.transcribe(wav: wav)
        XCTAssertEqual(healthy, "Ship it.", "2 vs 3: the original stays, two calls made")
        let healthyCalls = await calls.seen.count
        XCTAssertEqual(healthyCalls, 2)
    }

    /// The observer sees production's decision once per piece, with the
    /// piece's length — a long recording is decided piece by piece, and a
    /// bench that compares two whole transcripts would miss that.
    func testTheObserverSeesOneSelectionPerPieceThroughTheClient() async throws {
        // 30 s of speech-shaped bursts with pauses, so the chunker cuts it as
        // it cuts a long dictation (constant samples are never speech to it).
        var seed: UInt32 = 3
        var samples: [Int16] = []
        for burst in 0..<6 {
            samples += (0..<(4_000 * 16)).map { _ in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return Int16(truncatingIfNeeded: Int(seed >> 16) % 20_001 - 10_000)
            }
            samples += [Int16](repeating: 0, count: (burst == 5 ? 500 : 1_000) * 16)
        }
        let long = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let pieces = LongAudioChunker.pieces(pcm: long).count
        XCTAssertGreaterThanOrEqual(pieces, 2, "a long take is cut into pieces")
        var seen: [(SecondReading.Selection, Int)] = []
        SecondReading.selectionObserver = { seen.append(($0, $1)) }
        ParakeetClient.recognizerOverride = { data in data.prefix(SecondReading.prefix.count) == SecondReading.prefix ? "One two three four." : "" }
        UserDefaults.standard.set(true, forKey: FeatureFlags.overrideKey(for: SecondReading.flag))
        let text = try await ParakeetClient.shared.transcribe(wav: BenchReplay.wrap(long))
        XCTAssertEqual(seen.count, pieces, "one selection per piece")
        XCTAssertTrue(seen.allSatisfy { $0.0.replaced })
        XCTAssertGreaterThanOrEqual(seen.map(\.1).reduce(0, +), long.count, "the pieces' bytes cover the recording (a cap cut pre-rolls, so they may overlap)")
        XCTAssertFalse(text.isEmpty)
        SecondReading.selectionObserver = nil
        XCTAssertNil(SecondReading.selectionObserver, "nil in production")
    }

    /// The prefixed reading is the piece plus 40 ms, read as one call: a
    /// slice just under the chunker's threshold must not be cut into pieces
    /// once prefixed (review 2026-09-08 — a bench that sent the prefixed
    /// slice through `transcribe` got four pieces where production makes one).
    func testThePrefixedReadingIsNeverReChunkedAtTheBoundary() async throws {
        let slice = Data(repeating: 0x22, count: 19_980 * 32)   // 19.98 s: one piece; with the prefix 20.02 s
        XCTAssertEqual(LongAudioChunker.pieces(pcm: slice).count, 1)
        XCTAssertGreaterThan(Double((slice.count + SecondReading.prefix.count)) / 32_000, LongAudioChunker.maxSeconds, "the prefixed bytes would cross the threshold if re-chunked")
        let calls = Calls()
        ParakeetClient.recognizerOverride = { data in await calls.note(data); return data.count == slice.count ? "" : "One two three four." }
        UserDefaults.standard.set(true, forKey: FeatureFlags.overrideKey(for: SecondReading.flag))
        let text = try await ParakeetClient.shared.transcribe(wav: BenchReplay.wrap(slice))
        XCTAssertEqual(text, "One two three four.")
        let seen = await calls.seen
        XCTAssertEqual(seen.map(\.count), [slice.count, slice.count + SecondReading.prefix.count], "exactly two model calls: the piece, and the prefixed piece whole")
        // The bench's helper reads the same way: the piece-level call, not `transcribe`.
        await calls.reset()
        let reading = try await TwoAlignmentPolicyBenchTests.read(slice)
        XCTAssertTrue(reading.replaced)
        let benchSeen = await calls.seen
        XCTAssertEqual(benchSeen.map(\.count), [slice.count, slice.count + SecondReading.prefix.count])
    }

    private actor Calls {
        var seen: [Data] = []
        func note(_ d: Data) { seen.append(d) }
        func reset() { seen = [] }
    }
}
