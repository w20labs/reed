import XCTest
@testable import Reed

/// Pins the sealing rules of the live segmenter (latency step 2). Buffers
/// are fed as (speech?, ms) pairs; the segmenter answers in byte offsets.
final class SpeechSegmenterTests: XCTestCase {
    private let bpm = SpeechSegmenter.bytesPerMs

    /// Feed `ms` of audio in 85 ms buffers (~the tap's cadence); return
    /// every seal offset produced.
    private func feed(_ seg: inout SpeechSegmenter, speech: Bool, ms: Int) -> [Int] {
        var seals: [Int] = []
        var left = ms
        while left > 0 {
            let step = min(85, left)
            if let seal = seg.observe(isSpeech: speech, bytes: step * bpm) { seals.append(seal.end) }
            left -= step
        }
        return seals
    }

    func testSealsAtTheStartOfAPauseAfterEnoughSpeech() {
        var seg = SpeechSegmenter()
        XCTAssertTrue(feed(&seg, speech: true, ms: 3_000).isEmpty, "no cut while speaking")
        let seals = feed(&seg, speech: false, ms: 800)
        XCTAssertEqual(seals.count, 1)
        // The cut lands where the silence began (±one buffer), not at its end.
        XCTAssertEqual(Double(seals[0]) / Double(bpm), 3_000, accuracy: 90)
        XCTAssertEqual(seg.segmentStartByte, seals[0])
    }

    func testAShortPauseDoesNotCut() {
        var seg = SpeechSegmenter()
        _ = feed(&seg, speech: true, ms: 3_000)
        XCTAssertTrue(feed(&seg, speech: false, ms: 400).isEmpty, "a breath is not a boundary")
        XCTAssertTrue(feed(&seg, speech: true, ms: 1_000).isEmpty)
    }

    func testTooShortASegmentWaitsForMoreSpeech() {
        var seg = SpeechSegmenter()
        _ = feed(&seg, speech: true, ms: 1_000)
        XCTAssertTrue(feed(&seg, speech: false, ms: 1_500).isEmpty, "1 s of speech is a fragment, not a segment")
        _ = feed(&seg, speech: true, ms: 1_500)
        XCTAssertEqual(feed(&seg, speech: false, ms: 800).count, 1, "once long enough, the next pause cuts")
    }

    func testLeadingSilenceNeverCuts() {
        var seg = SpeechSegmenter()
        XCTAssertTrue(feed(&seg, speech: false, ms: 5_000).isEmpty, "nothing said yet — nothing to seal")
    }

    func testNonStopSpeechSealsAtTheCap() {
        var seg = SpeechSegmenter()
        let seals = feed(&seg, speech: true, ms: 65_000)
        XCTAssertEqual(seals.count, 3, "three cap-sized cuts in 65 s of continuous speech")
        // Uniform level → the quiet-point search has nothing to prefer, so the
        // cut lands within the search window before the cap.
        XCTAssertEqual(Double(seals[0]) / Double(bpm), Double(SpeechSegmenter.maxSegmentMs),
                       accuracy: Double(SpeechSegmenter.capSearchWindowMs))
    }

    /// The run-on regression (2026-08-27): a fixed cut at the cap landed
    /// mid-word. With levels supplied, the cap cut must land on the quietest
    /// buffer in the trailing window — between words — not at the cap byte.
    func testCapCutPrefersTheQuietestRecentBuffer() {
        var seg = SpeechSegmenter()
        var seals: [Int] = []
        var ms = 0
        while ms < SpeechSegmenter.maxSegmentMs + 100 {
            // A dip 1.2 s before the cap: the between-words moment.
            let dipAt = SpeechSegmenter.maxSegmentMs - 1_200
            let db = (ms >= dipAt && ms < dipAt + 85) ? -40.0 : -20.0
            if let s = seg.observe(isSpeech: true, db: db, bytes: 85 * bpm) { seals.append(s.end) }
            ms += 85
        }
        XCTAssertEqual(seals.count, 1)
        XCTAssertEqual(Double(seals[0]) / Double(bpm), Double(SpeechSegmenter.maxSegmentMs - 1_200), accuracy: 90,
                       "the cut must land on the dip, not the cap")
    }

    func testSegmentsChainWithoutOverlapOrGap() {
        var seg = SpeechSegmenter()
        var seals: [Int] = []
        for _ in 0..<3 {
            seals += feed(&seg, speech: true, ms: 4_000)
            seals += feed(&seg, speech: false, ms: 900)
        }
        XCTAssertEqual(seals.count, 3)
        XCTAssertEqual(seals, seals.sorted(), "offsets strictly increase")
        XCTAssertEqual(seg.segmentStartByte, seals.last)
        XCTAssertLessThanOrEqual(seg.openSegmentBytes, 900 * bpm + 85 * bpm, "the open segment is just the trailing pause")
    }

    /// A pause seal is a sentence boundary: the next segment starts exactly
    /// at the cut. A cap seal is not: the next segment pre-rolls so the
    /// recognizer doesn't open cold mid-phrase (2026-08-28).
    func testSealReasonsAndCapPreRoll() {
        var seg = SpeechSegmenter()
        var pause: SpeechSegmenter.Seal?
        for _ in 0..<40 { if let s = seg.observe(isSpeech: true, bytes: 85 * bpm) { pause = s } }
        for _ in 0..<12 { if let s = seg.observe(isSpeech: false, bytes: 85 * bpm) { pause = s } }
        XCTAssertEqual(pause?.reason, .pause)
        XCTAssertEqual(pause?.nextStart, pause?.end, "no pre-roll at a pause")

        var seg2 = SpeechSegmenter()
        var cap: SpeechSegmenter.Seal?
        var ms = 0
        while cap == nil, ms < 30_000 {
            cap = seg2.observe(isSpeech: true, db: -20, bytes: 85 * bpm)
            ms += 85
        }
        XCTAssertEqual(cap?.reason, .cap)
        let preRollMs = cap.map { ($0.end - $0.nextStart) / bpm } ?? -1
        XCTAssertGreaterThanOrEqual(preRollMs, SpeechSegmenter.capPreRollMinMs)
        XCTAssertLessThanOrEqual(preRollMs, SpeechSegmenter.capPreRollMaxMs + 85)
        XCTAssertEqual(seg2.segmentStartByte, cap?.nextStart)
    }

    /// The pre-roll starts on the previous WORD boundary — the quietest
    /// buffer in the pre-roll window — not at a fixed distance (a fixed
    /// 300 ms began mid-word and the recognizer produced "start to").
    func testCapPreRollStartsAtTheQuietestBufferBeforeTheCut() {
        var seg = SpeechSegmenter()
        var cap: SpeechSegmenter.Seal?
        var ms = 0
        let cutAt = SpeechSegmenter.maxSegmentMs - 1_200
        let wordGapAt = cutAt - 600
        while cap == nil, ms < 30_000 {
            let db = (ms >= cutAt && ms < cutAt + 85) ? -40.0 : (ms >= wordGapAt && ms < wordGapAt + 85) ? -35.0 : -20.0
            cap = seg.observe(isSpeech: true, db: db, bytes: 85 * bpm)
            ms += 85
        }
        XCTAssertEqual(Double(cap?.end ?? 0) / Double(bpm), Double(cutAt), accuracy: 90)
        XCTAssertEqual(Double(cap?.nextStart ?? 0) / Double(bpm), Double(wordGapAt), accuracy: 90,
                       "the next segment opens on the word gap before the cut")
    }
}
