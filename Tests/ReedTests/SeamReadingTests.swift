import XCTest
@testable import Reed

/// The seam reading without models: what the window is, what the
/// recognizer's text across the seal decides, and how the coordinator
/// turns readings into assembly verdicts on the production path.
final class SeamReadingTests: XCTestCase {
    private typealias Piece = Coordinator.Piece

    // MARK: - The decision

    func testTheMarkBetweenTheHeadsLastWordAndTheNextsFirstDecidesTheSeam() {
        let head = "We ship on Friday.", next = "We lose the weekend."
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "on Friday, we lose the"), .mark(.comma))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "ship on Friday. We lose the"), .mark(.period))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "on friday we lose"), .mark(.nothing))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "Friday; we lose"), .mark(.comma), "a semicolon is a clause break")
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "Friday? We lose"), .mark(.period), "any terminal mark ends the sentence")
    }

    func testAReadingThatCannotPlaceBothWordsAdjacentDecidesNothing() {
        let head = "We ship on Friday.", next = "We lose the weekend."
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: ""), .undecided(.emptyWindow))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "we ship on Thursday we lose"), .undecided(.headWordMissing))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "on Friday the weekend"), .undecided(.nameAfterNothing),
                       "the window dropped the next's first word: a mark would still be the seam's, but \"nothing\" needs that word's case")
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "on Friday, the weekend"), .mark(.comma))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "on Friday. Lose the weekend"), .mark(.period))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "on Friday it was fine"), .undecided(.nextWordMissing))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "on Friday then the weekend"), .undecided(.notAdjacent))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "on Friday then we lose"), .undecided(.notAdjacent),
                       "a word between them: the mark read would not be the seam's")
        XCTAssertEqual(SeamReading.decide(head: "", next: next, window: "we lose"), .undecided(.headWordMissing))
        XCTAssertEqual(SeamReading.decide(head: head, next: "", window: "Friday"), .undecided(.nextWordMissing))
    }

    func testACapitalAfterNoMarkIsANameAndIsLeftAlone() {
        XCTAssertEqual(SeamReading.decide(head: "We told.", next: "Dana to deploy.", window: "we told Dana to"), .undecided(.nameAfterNothing))
        XCTAssertEqual(SeamReading.decide(head: "We told.", next: "I should go.", window: "we told I should"), .mark(.nothing), "\"I\" is not a name")
        XCTAssertEqual(SeamReading.decide(head: "We called.", next: "Dana to arrange it.", window: "we called to arrange it"), .undecided(.nameAfterNothing),
                       "the window skipped the opener: its case is unknown, so it may be a name")
        XCTAssertEqual(SeamReading.decide(head: "We called.", next: "IT to arrange it.", window: "we called it to arrange"), .undecided(.nameAfterNothing),
                       "an acronym would come out \"iT\"")
        XCTAssertEqual(SeamReading.decide(head: "We called.", next: "Will to arrange it.", window: "we called will to arrange"), .mark(.nothing),
                       "the window heard the opener in lower case: the recognizer read it as a word")
        XCTAssertEqual(SeamReading.decide(head: "We called.", next: "Dana, to arrange it.", window: "we called, to arrange"), .mark(.comma),
                       "a comma lowers only listed openers, so a skipped opener is safe")
    }

    func testAFillerAtThePauseIsDroppedAndItsMarkMovesToTheWordBefore() {
        let head = "Let's teach me on how to train.", next = "This model."
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "how to train uh this model"), .mark(.nothing))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "how to train, um this model"), .mark(.comma))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "how to train um, this model"), .mark(.comma), "the mark on the filler is the seam's")
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "how to train. Um, this model"), .mark(.period), "a marked word keeps its own mark")
        XCTAssertEqual(SeamReading.spokenTokens("we had um, when"), ["we", "had,", "when"])
        XCTAssertEqual(SeamReading.spokenTokens("um uh we"), ["we"], "a filler with nothing before it just goes")
    }

    func testASpellingOrOneLetterMissHearingStillAligns() {
        XCTAssertEqual(SeamReading.decide(head: "Send it to his counselor.", next: "What does he need?", window: "to his counsellor. What does he"), .mark(.period),
                       "one letter more in a long word is a spelling")
        XCTAssertEqual(SeamReading.decide(head: "Send it to his counselor.", next: "What does he need?", window: "to his counselar. What does he"), .mark(.period))
        XCTAssertEqual(SeamReading.decide(head: "The application every.", next: "Pretty much I only use it.", window: "application very uh pretty much"), .undecided(.headWordMissing),
                       "a short word is never bridged onto a longer one")
        XCTAssertEqual(SeamReading.decide(head: "In common app.", next: "And then send it.", window: "in common up and then send"), .undecided(.headWordMissing),
                       "a different word, and the seam stays")
        XCTAssertEqual(SeamReading.decide(head: "First launch countries.", next: "I'm considering it.", window: "launch countries. I am considering"), .mark(.period),
                       "a contraction the window heard as two words still aligns on its base")
        XCTAssertEqual(SeamReading.decide(head: "Better sleepers.", next: "It will help.", window: "better sleepers. Um um it's"), .mark(.period))
        XCTAssertTrue(SeamReading.matches("i'm", "i"))
        XCTAssertTrue(SeamReading.matches("it", "it's"))
        XCTAssertFalse(SeamReading.matches("don't", "do"))
        XCTAssertFalse(SeamReading.matches("here", "there"), "an insertion is never bridged")
        XCTAssertFalse(SeamReading.matches("app", "up"))
        XCTAssertFalse(SeamReading.matches("the", "that"))
        XCTAssertFalse(SeamReading.matches("to", "do"), "three letters are too few to fuzz")
    }

    func testAQuestionOrExclamationTheHeadHeardWholeIsNeverTakenAway() {
        let head = "What do you think, recommending?", next = "To change I need all that."
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "you think recommending to change I"), .undecided(.questionKept))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "recommending, to change"), .undecided(.questionKept))
        XCTAssertEqual(SeamReading.decide(head: head, next: next, window: "recommending? To change"), .mark(.period), "the same mark is a period verdict: the text stays")
        XCTAssertEqual(SeamReading.decide(head: "Go!", next: "Now.", window: "go now"), .undecided(.questionKept))
    }

    // MARK: - The window

    func testTheWindowSkipsTheLeadingSilenceOfTheNextSide() {
        // 3 s of speech, 3 s of silence, 3 s of speech; the seal at the silence's start.
        var pcm = Data()
        pcm.append(Self.tone(seconds: 3)); pcm.append(Data(count: 3 * 32_000)); pcm.append(Self.tone(seconds: 3))
        let seal = 3 * 32_000
        XCTAssertEqual(SeamReading.leadingSilence(pcm: pcm, from: seal, to: pcm.count, speechAt: 0..<seal), 3 * 32_000)
        let window = SeamReading.window(pcm: pcm, seal: seal, headStart: 0, nextEnd: pcm.count)
        XCTAssertNotNil(window)
        XCTAssertGreaterThanOrEqual(window?.count ?? 0, (2 + 3 + 2 - 1) * 32_000, "about two seconds before, the silence, two seconds of speech after")
        XCTAssertLessThanOrEqual(window?.count ?? 0, (2 + 3 + 2 + 1) * 32_000)
        XCTAssertEqual(SeamReading.leadingSilence(pcm: pcm, from: 0, to: pcm.count, speechAt: 0..<seal), 0, "speech from the start")
        var quiet = Data(count: 6 * 32_000)
        quiet.append(Self.tone(seconds: 1))
        XCTAssertNil(SeamReading.leadingSilence(pcm: Self.tone(seconds: 3) + quiet, from: 3 * 32_000, to: 10 * 32_000, speechAt: 0..<(3 * 32_000)))
        XCTAssertNil(SeamReading.window(pcm: Self.tone(seconds: 3) + quiet, seal: 3 * 32_000, headStart: 0, nextEnd: 10 * 32_000),
                     "no speech within the scan: a pause that long is left as it is")
    }

    func testALoneBlipAfterTheSealIsNotTheNextWords() {
        // frames: 4 of speech (an "um"), 20 of silence, then speech
        let blip = [Bool](repeating: true, count: 4) + [Bool](repeating: false, count: 20) + [Bool](repeating: true, count: 30)
        XCTAssertEqual(SeamReading.firstSpeechRun(blip), 24)
        XCTAssertEqual(SeamReading.firstSpeechRun([Bool](repeating: true, count: 15)), 0, "a run exactly as long as the minimum")
        XCTAssertNil(SeamReading.firstSpeechRun([Bool](repeating: true, count: 14)), "one frame short")
        let gapped = [true, true, true, true, true, false, false, true, true, true, true, true, true, true, true, true]
        XCTAssertEqual(SeamReading.firstSpeechRun(gapped), 0, "a gap of 40 ms inside a word does not restart the run")
        XCTAssertNil(SeamReading.firstSpeechRun([]))
    }

    func testRoomNoiseAfterTheSealIsSilenceJudgedAgainstTheHeadsLevel() {
        // Speech, then noise 40 dB down for 1.5 s, then speech: the lead is the noise, not zero.
        var pcm = Self.tone(seconds: 3)
        pcm.append(Self.tone(seconds: 1, amplitude: 80)); pcm.append(Data(count: 16_000)); pcm.append(Self.tone(seconds: 2))
        let seal = 3 * 32_000
        XCTAssertEqual(SeamReading.leadingSilence(pcm: pcm, from: seal, to: pcm.count, speechAt: 0..<seal), 48_000)
    }

    func testTheWindowsEndsLandOnTheQuietestFrameNearby() {
        // Speech with one silent frame inside each end's search range (frame-aligned to that range's start).
        var pcm = Self.tone(seconds: 10)
        let seal = 5 * 32_000, frame = SeamReading.frameMs * SeamReading.bytesPerMs
        let beforeRange = (seal - 64_000 - SeamReading.cutSearch)..<(seal - 64_000 + SeamReading.cutSearch)
        let afterRange = (seal + 64_000 - SeamReading.cutSearch)..<(seal + 64_000 + SeamReading.cutSearch)
        let dipBefore = beforeRange.lowerBound + 29 * frame, dipAfter = afterRange.lowerBound + 10 * frame
        pcm.replaceSubrange(dipBefore..<(dipBefore + frame), with: Data(count: frame))
        pcm.replaceSubrange(dipAfter..<(dipAfter + frame), with: Data(count: frame))
        XCTAssertEqual(SeamReading.quietestFrame(pcm: pcm, in: beforeRange), dipBefore)
        XCTAssertEqual(SeamReading.quietestFrame(pcm: pcm, in: afterRange), dipAfter)
        XCTAssertEqual(SeamReading.window(pcm: pcm, seal: seal, headStart: 0, nextEnd: pcm.count)?.count, dipAfter - dipBefore)
    }

    private static func tone(seconds: Int, amplitude: Double = 8_000) -> Data {
        var samples = [Int16](repeating: 0, count: seconds * 16_000)
        for i in samples.indices { samples[i] = Int16(amplitude * sin(Double(i) * 2 * .pi * 220 / 16_000)) }
        return samples.withUnsafeBytes { Data($0) }
    }


    func testTheWindowIsTwoSecondsEachSideClampedToTheHalves() {
        let pcm = Self.tone(seconds: 10)
        let seal = 5 * 32_000
        XCTAssertEqual(SeamReading.window(pcm: pcm, seal: seal, headStart: 0, nextEnd: pcm.count)?.count, 4 * 32_000)
        XCTAssertEqual(SeamReading.window(pcm: pcm, seal: seal, headStart: seal - 32_000, nextEnd: seal + 16_000)?.count, 48_000,
                       "a short head or next bounds the window")
        XCTAssertNil(SeamReading.window(pcm: pcm, seal: seal, headStart: seal - 8_000, nextEnd: pcm.count), "250 ms of head is no reading")
        XCTAssertNil(SeamReading.window(pcm: pcm, seal: seal, headStart: 0, nextEnd: seal + 8_000), "250 ms of next is no reading")
        XCTAssertNil(SeamReading.window(pcm: pcm, seal: pcm.count + 32_000, headStart: 0, nextEnd: pcm.count + 64_000), "a seal beyond the recording")
        XCTAssertEqual(SeamReading.window(pcm: pcm, seal: seal, headStart: 0, nextEnd: pcm.count + 32_000)?.count, 4 * 32_000, "a next end past the recording is clamped")
    }

    // MARK: - The coordinator's readings

    @MainActor
    func testReadSeamsCutsTheWindowAtTheSealAndHandsAssemblyTheVerdict() async {
        let coordinator = Coordinator()
        let saved = Coordinator.transcribeOverride
        defer { Coordinator.transcribeOverride = saved }
        var windowsSeen: [Int] = []
        Coordinator.transcribeOverride = { wav in
            windowsSeen.append(wav.count - 44)
            return "on Friday, we lose the"
        }
        let pcm = Self.tone(seconds: 12)
        let pieces = [Piece(text: "We ship on Friday.", sealedBy: .pause), Piece(text: "We lose the weekend.", sealedBy: nil)]
        let reads = await coordinator.readSeams(pieces: pieces, ranges: [0..<(6 * 32_000), (6 * 32_000)..<pcm.count], pcm: pcm)
        XCTAssertEqual(reads.verdicts, [1: .comma])
        XCTAssertEqual(reads.undecided, [:])
        XCTAssertEqual(reads.unread, 0)
        XCTAssertEqual(windowsSeen, [4 * 32_000], "one read, two seconds each side of the seal")
        XCTAssertEqual(reads.msPerSeam.keys.sorted(), [1])
        let text = await Coordinator.assembleSegments(pieces, verdicts: reads.verdicts)
        XCTAssertEqual(text, "We ship on Friday, we lose the weekend.")
    }

    /// The release path hands over the recording minus its WAV header. A
    /// Data slice keeps the parent's indices while every byte range is an
    /// offset from zero, so the bytes the recognizer gets must be the same
    /// window the pure function cuts from zero-based audio.
    @MainActor
    func testASlicedRecordingIsReadFromOffsetZero() async {
        let coordinator = Coordinator()
        let saved = Coordinator.transcribeOverride
        defer { Coordinator.transcribeOverride = saved }
        Coordinator.transcribeOverride = { _ in "on Friday, we lose the" }
        var captured: Data?
        SeamReading.windowObserverForTests = { captured = $0 }
        defer { SeamReading.windowObserverForTests = nil }
        let zeroBased = Self.tone(seconds: 12)
        var wav = Data(count: 44)
        wav.append(zeroBased)
        let sliced = wav.dropFirst(44)
        XCTAssertEqual(sliced.startIndex, 44, "the slice keeps its parent's indices")
        let seal = 6 * 32_000
        let pieces = [Piece(text: "We ship on Friday.", sealedBy: .pause), Piece(text: "We lose the weekend.", sealedBy: nil)]
        let reads = await coordinator.readSeams(pieces: pieces, ranges: [0..<seal, seal..<sliced.count], pcm: sliced)
        XCTAssertEqual(reads.verdicts, [1: .comma])
        let expected = SeamReading.window(pcm: zeroBased, seal: seal, headStart: 0, nextEnd: zeroBased.count)
        XCTAssertNotNil(expected)
        XCTAssertEqual(captured.map { [UInt8]($0) }, expected.map { [UInt8]($0) }, "the window's bytes, not bytes shifted by the header")
    }

    @MainActor
    func testOnlyPauseSeamsWithSealPointsAreRead() async {
        let coordinator = Coordinator()
        let saved = Coordinator.transcribeOverride
        defer { Coordinator.transcribeOverride = saved }
        var reads = 0
        Coordinator.transcribeOverride = { _ in reads += 1; return "x. Y" }
        let pcm = Self.tone(seconds: 20)
        let pieces = [Piece(text: "One two.", sealedBy: .cap), Piece(text: "Three four.", sealedBy: .pause),
                      Piece(text: "Five six.", sealedBy: .pause), Piece(text: "Seven eight.", sealedBy: nil)]
        let ranges: [Range<Int>?] = [0..<160_000, 160_000..<320_000, nil, 480_000..<640_000]
        let result = await coordinator.readSeams(pieces: pieces, ranges: ranges, pcm: pcm)
        XCTAssertEqual(reads, 0, "the cap seam is never read; the pause seams around the piece without seal points cannot be")
        XCTAssertEqual(result.unread, 2)
        XCTAssertEqual(result.verdicts, [:])
    }

    @MainActor
    func testTheBreathRuleKeepsPrecedenceOverAPeriodReading() async {
        let coordinator = Coordinator()
        let saved = Coordinator.transcribeOverride
        defer { Coordinator.transcribeOverride = saved }
        let pcm = Self.tone(seconds: 12)
        for (head, heard) in [("We are going to.", "going to. Spend the"), ("We are going to.", "going to, spend the"),
                              ("We are going to.", "going to spend the"), ("Look at the.", "at the, spend the"), ("I think that.", "think that. Spend the")] {
            Coordinator.transcribeOverride = { _ in heard }
            let pieces = [Piece(text: head, sealedBy: .pause), Piece(text: "Spend the weekend.", sealedBy: nil)]
            let reads = await coordinator.readSeams(pieces: pieces, ranges: [0..<192_000, 192_000..<pcm.count], pcm: pcm)
            XCTAssertEqual(reads.verdicts, [:], "\(head) | \(heard)")
            XCTAssertEqual(reads.undecided, [1: .breathRule], "\(head) | \(heard)")
            let text = await Coordinator.assembleSegments(pieces, verdicts: reads.verdicts)
            XCTAssertEqual(text, head.dropLast() + " spend the weekend.", "glued as a breath, whatever the window said")
        }
    }

    @MainActor
    func testACorrectionCueSeamIsAssemblysAndIsNeverRead() async {
        let coordinator = Coordinator()
        let saved = Coordinator.transcribeOverride
        defer { Coordinator.transcribeOverride = saved }
        var reads = 0
        Coordinator.transcribeOverride = { _ in reads += 1; return "Bob, wait no Alice" }
        let pcm = Self.tone(seconds: 12)
        let pieces = [Piece(text: "Ask Bob.", sealedBy: .pause), Piece(text: "Wait, no, Alice.", sealedBy: nil)]
        let result = await coordinator.readSeams(pieces: pieces, ranges: [0..<192_000, 192_000..<pcm.count], pcm: pcm)
        XCTAssertEqual(reads, 0, "both halves are re-cleaned together by assembly; a verdict would be ignored")
        XCTAssertEqual(result.verdicts, [:])
        XCTAssertEqual(result.unread, 1)
    }

    @MainActor
    func testARecognizerFailureLeavesTheSeamUnread() async {
        struct Boom: Error {}
        let coordinator = Coordinator()
        let saved = Coordinator.transcribeOverride
        defer { Coordinator.transcribeOverride = saved }
        Coordinator.transcribeOverride = { _ in throw Boom() }
        let pcm = Self.tone(seconds: 12)
        let pieces = [Piece(text: "We ship on Friday.", sealedBy: .pause), Piece(text: "We lose the weekend.", sealedBy: nil)]
        let reads = await coordinator.readSeams(pieces: pieces, ranges: [0..<192_000, 192_000..<pcm.count], pcm: pcm)
        XCTAssertEqual(reads.verdicts, [:])
        XCTAssertEqual(reads.unread, 1)
    }

    // MARK: - The seal points travel into the review copy

    func testTheCollectorKeepsEachSegmentsSealPoints() throws {
        let review = DictationReview(keepsContent: true)
        review.segment(0, boundary: .pause, raw: "a", corrected: "a", pcmRange: 0..<64_000)
        review.segment(1, boundary: .tail, raw: "b", corrected: "b", pcmRange: 64_000..<100_000)
        review.segment(2, boundary: .tail, raw: "c", corrected: "c")
        review.delivered(segment: 0, text: "A.\n\nStill a.")
        let record = review.finish(Self.delivery)
        XCTAssertEqual(record.segments.map { $0.delivered }, ["A.\n\nStill a.", nil, nil], "what assembly received, lines and all")
        XCTAssertEqual(record.segments.map { $0.pcmStart }, [0, 64_000, nil])
        XCTAssertEqual(record.segments.map { $0.pcmEnd }, [64_000, 100_000, nil])
        XCTAssertEqual(record.versions.schema, 6)
        let back = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Self.encoder.encode(record))
        XCTAssertEqual(back.segments.map { $0.pcmEnd }, [64_000, 100_000, nil])
    }

    /// A copy written before schema 6 has no seal points; it still decodes,
    /// and the bench then locates seams from the segment lengths.
    func testASchemaFiveCopyStillDecodesWithoutSealPoints() throws {
        let review = DictationReview(keepsContent: true)
        review.segment(0, boundary: .pause, raw: "a", corrected: "a", audioMs: 900, pcmRange: 0..<28_800)
        review.segment(1, boundary: .tail, raw: "b", corrected: "b", audioMs: 500, pcmRange: 28_800..<44_800)
        var json = try JSONSerialization.jsonObject(with: Self.encoder.encode(review.finish(Self.delivery))) as! [String: Any]
        var versions = json["versions"] as! [String: Any]
        versions["schema"] = 5
        json["versions"] = versions
        json["segments"] = (json["segments"] as! [[String: Any]]).map { segment in
            var older = segment
            older.removeValue(forKey: "pcmStart"); older.removeValue(forKey: "pcmEnd")
            return older
        }
        let record = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(record.versions.schema, 5)
        XCTAssertEqual(record.segments.map { $0.pcmStart }, [nil, nil])
        XCTAssertEqual(record.segments.map { $0.audioMs }, [900, 500])
        XCTAssertEqual(SeamReadingBenchTests.ranges(segments: record.segments), [0..<28_800, 28_800..<44_800],
                       "pause seals locate from the lengths alone")
        var capped = record.segments
        capped[0].boundary = .cap
        XCTAssertEqual(SeamReadingBenchTests.ranges(segments: capped), [0..<28_800, nil], "after a cap cut the seal is unknown")
    }

    private static let delivery = DictationReview.Delivery(
        injection: .init(text: "a b c", target: nil, method: "paste"),
        timings: .init(totalSeconds: 1), mode: "localOnly", engine: "parakeet")
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
