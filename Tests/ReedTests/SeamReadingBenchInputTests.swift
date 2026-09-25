import XCTest
@testable import Reed

/// The seam bench's inputs, pinned without models (review 2026-09-10,
/// findings 4–7): seal points after a gap or a cap cut are unknown; a
/// segment's text is what was delivered, a rebuild only for older copies
/// and flagged; a copy naming a recording that is gone is listed, not
/// dropped; a changed seam is a changed text.
final class SeamReadingBenchInputTests: XCTestCase {
    private typealias Piece = Coordinator.Piece
    private typealias Bench = SeamReadingBenchTests

    func testSealPointsFromLengthsStopAtAGapOrACapCut() {
        var a = ReviewRecord.Segment(index: 0, boundary: .pause, raw: "a", corrected: "a"); a.audioMs = 1_000
        var b = ReviewRecord.Segment(index: 1, boundary: .pause, raw: "b", corrected: "b"); b.audioMs = 500
        var c = ReviewRecord.Segment(index: 2, boundary: .tail, raw: "c", corrected: "c"); c.audioMs = 700
        XCTAssertEqual(Bench.ranges(segments: [a, b, c]), [0..<32_000, 32_000..<48_000, 48_000..<70_400])
        var skipped = b; skipped.index = 2
        var after = c; after.index = 3
        XCTAssertEqual(Bench.ranges(segments: [a, skipped, after]), [0..<32_000, nil, nil], "a missing index: the audio between is unrecorded")
        var capped = a; capped.boundary = .cap
        XCTAssertEqual(Bench.ranges(segments: [capped, b, c]), [0..<32_000, nil, nil], "a cap cut's pre-roll moves the next start")
        var live = [a, b, c]
        for i in live.indices { live[i].pcmStart = i * 10; live[i].pcmEnd = i * 10 + 5 }
        XCTAssertEqual(Bench.ranges(segments: live), [0..<5, 10..<15, 20..<25], "recorded seal points win over lengths")
    }

    func testAPieceIsTheDeliveredTextAndOnlyOlderCopiesAreRebuilt() {
        var a = ReviewRecord.Segment(index: 0, boundary: .pause, raw: "a b", corrected: "a b"); a.delivered = "A.\n\nB."
        let b = ReviewRecord.Segment(index: 1, boundary: .tail, raw: "c", corrected: "c")
        let chunks = [ReviewRecord.Chunk(segments: [0], input: "a", repairHint: nil, attempts: [], delivered: "A.", outcome: .modelAccepted, reason: nil),
                      ReviewRecord.Chunk(segments: [0], input: "b", repairHint: nil, attempts: [], delivered: "B.", outcome: .modelAccepted, reason: nil),
                      ReviewRecord.Chunk(segments: [1], input: "c", repairHint: nil, attempts: [], delivered: "C.", outcome: .notAttempted, reason: "x")]
        let (pieces, reconstructed) = Bench.pieces(segments: [a, b], chunks: chunks)
        XCTAssertEqual(pieces.map(\.text), ["A.\n\nB.", "C."], "the recorded delivery, lines and all, beats the chunks")
        XCTAssertTrue(reconstructed, "one segment had no delivered text and was rebuilt")
        var bDelivered = b; bDelivered.delivered = "C."
        XCTAssertFalse(Bench.pieces(segments: [a, bDelivered], chunks: chunks).reconstructed)
        XCTAssertEqual(pieces.map(\.sealedBy), [.pause, nil])
    }

    func testEveryCopyWithAPauseIsAnInputOrASkipByName() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "seam-inputs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = WAVWriter.wrap(pcm: Data(count: 64_000), sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        let present = try LocalReviewStore.write(Self.record(indices: [0, 1], startedAt: Date(timeIntervalSince1970: 1_700_000_000)), audio: audio, in: dir)
        let gone = try LocalReviewStore.write(Self.record(indices: [0, 1], startedAt: Date(timeIntervalSince1970: 1_700_000_100)), audio: audio, in: dir)
        try FileManager.default.removeItem(at: dir.appending(path: String(gone.lastPathComponent.dropLast(5)) + ".wav"))
        let never = try LocalReviewStore.write(Self.record(indices: [0, 1], startedAt: Date(timeIntervalSince1970: 1_700_000_200)), in: dir)
        let gapped = try LocalReviewStore.write(Self.record(indices: [0, 2], startedAt: Date(timeIntervalSince1970: 1_700_000_300)), audio: audio, in: dir)
        let gappedAndGone = try LocalReviewStore.write(Self.record(indices: [0, 2], startedAt: Date(timeIntervalSince1970: 1_700_000_400)), audio: audio, in: dir)
        try FileManager.default.removeItem(at: dir.appending(path: String(gappedAndGone.lastPathComponent.dropLast(5)) + ".wav"))
        let cued = try LocalReviewStore.write(Self.record(indices: [0, 1], startedAt: Date(timeIntervalSince1970: 1_700_000_500), next: "Wait, no, Alice."),
                                              audio: audio, in: dir)
        let inputs = try Bench.corpusInputs(in: dir)
        let byID = Dictionary(uniqueKeysWithValues: inputs.copies.map { ($0.id, $0) })
        XCTAssertEqual(Set(byID.keys), [present.lastPathComponent, gone.lastPathComponent, never.lastPathComponent, gappedAndGone.lastPathComponent])
        XCTAssertEqual(byID[gappedAndGone.lastPathComponent]?.missingRecording, true,
                       "a missing recording is a failed run before any skip can hide it")
        XCTAssertNotNil(byID[present.lastPathComponent]?.audio)
        XCTAssertNil(byID[gone.lastPathComponent]?.audio)
        XCTAssertEqual(byID[gone.lastPathComponent]?.missingRecording, true, "named but gone: listed, and the run fails on it")
        XCTAssertEqual(byID[never.lastPathComponent]?.missingRecording, false, "never had one: listed, reported")
        XCTAssertEqual(inputs.skipped.map { $0.id }, [gapped.lastPathComponent, cued.lastPathComponent])
        XCTAssertEqual(inputs.skipped.map { $0.why }, [.gapped, .cued], "a correction cue's text depends on a model call: not measured")
    }

    func testAChangedSeamIsAChangedTextNotAChangedDecision() async {
        let breath = [Piece(text: "We are going to.", sealedBy: .pause), Piece(text: "Spend the weekend.", sealedBy: nil)]
        let breathText = await Coordinator.assembleSegments(breath)
        let none = await Bench.changedSeams(pieces: breath, verdicts: [1: .nothing], baseline: breathText)
        XCTAssertEqual(none, 0, "the breath rule glued already: the same text")
        let pieces = [Piece(text: "We ship on Friday.", sealedBy: .pause), Piece(text: "We lose the weekend.", sealedBy: nil)]
        let text = await Coordinator.assembleSegments(pieces)
        let period = await Bench.changedSeams(pieces: pieces, verdicts: [1: .period], baseline: text)
        XCTAssertEqual(period, 0, "a period over a sentence end restates it")
        let comma = await Bench.changedSeams(pieces: pieces, verdicts: [1: .comma], baseline: text)
        XCTAssertEqual(comma, 1)
    }

    private static func record(indices: [Int], startedAt: Date, next: String? = nil) -> ReviewRecord {
        let review = DictationReview(keepsContent: true, startedAt: startedAt)
        for (position, index) in indices.enumerated() {
            let last = position == indices.count - 1
            review.segment(index, boundary: last ? .tail : .pause, raw: "w\(index)", corrected: "w\(index)")
            review.delivered(segment: index, text: position > 0 ? (next ?? "W\(index).") : "W\(index).")
        }
        return review.finish(.init(injection: .init(text: "W.", target: nil, method: "paste"), timings: .init(totalSeconds: 1),
                                   mode: "localOnly", engine: "parakeet"))
    }
}
