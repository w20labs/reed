import XCTest
@testable import Reed

/// The seam reading measured where it counts (seam experiment,
/// 2026-09-10): every local copy with a recording and a pause seam is
/// re-assembled from the texts the app delivered per segment — exactly
/// what assembly received live — with and without readings of the audio
/// across each seal, taken where the app sealed (schema 6 seal points;
/// older copies locate a seal from the segment lengths only while every
/// earlier seal was a pause). Each pause seam is then read in both texts
/// and, when a human set one, in the reference — sentence end, clause
/// break, or nothing — by word alignment. Words must survive every join;
/// the latency of every read is reported. No cleanup model runs: the
/// texts are the copy's, only the recognizer reads windows.
///
/// Gated: REED_SEAM_READ_BENCH=1 swift test --filter SeamReadingBenchTests
///        REED_REVIEW_CORPUS_DIR=<dir>  (default: the app's review directory)
///
/// Output lines (content-free):
///   SW|copy|<id>|<reviewed 0/1>|<pause_seams>|<located>|<period>|<comma>|<nothing>|<undecided>|<changed>|<ms>
///   SW|undecided|<id>|<piece>|<why>
///   SW|scored|<id>|<seam>|<reference>|<off>|<on>        reviewed copies: end / clause / plain per reading
///   SW|mismatch|<id>                                      a copy with delivered texts whose re-assembly differs from its own text (reported)
///   SW|unfaithful|<id>                                    an older copy whose rebuilt segments do not re-assemble to its own text (not an input)
///   SW|skipped|<id>|gapped · SW|skipped|<id>|cued        a segment index is missing: the live input cannot be rebuilt · a correction cue crosses a pause: its text depends on a model call
///   SW|missing|<id> · SW|no_recording|<id>               a named recording that is gone (fails the run) · a copy from before recordings were kept
///   SW|tally|copies=.. reviewed=.. seams=.. located=.. read=.. period=.. comma=.. nothing=.. undecided=.. changed=..
///            words_changed=.. ms_p50=.. ms_max=.. scored=.. corrected=.. broken=.. same_right=.. same_wrong=.. unscorable=.. mismatch=..
///            unreadable=.. missing=.. no_recording=.. gapped=.. unfaithful=.. cued=..
/// A changed word, an unreadable or a missing recording fails the bench. Nothing scored is not a pass.
final class SeamReadingBenchTests: XCTestCase {
    typealias Reading = SeamRulesBenchTests.Reading

    @MainActor
    func testSeamReadingsAgainstTheCorpus() async throws {
        guard ProcessInfo.processInfo.environment["REED_SEAM_READ_BENCH"] == "1" else {
            throw XCTSkip("set REED_SEAM_READ_BENCH=1 to run (reads the audio across every pause seam of the review corpus)")
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let overrideKey = FeatureFlags.overrideKey(for: SeamRules.flag)
        let savedOverride = UserDefaults.standard.object(forKey: overrideKey)
        defer {
            if let savedOverride { UserDefaults.standard.set(savedOverride, forKey: overrideKey) } else { UserDefaults.standard.removeObject(forKey: overrideKey) }
        }
        UserDefaults.standard.set(false, forKey: overrideKey)   // the clause rule off, as shipped: the reading alone is measured
        let inputs = try Self.corpusInputs(in: ReviewCorpusBenchTests.corpusDirectory())
        var tally = Tally()
        for (id, why) in inputs.skipped { print("SW|skipped|\(id)|\(why.rawValue)"); tally.count(why) }
        print("SW|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|copies=\(inputs.copies.count)|reviewed=\(inputs.copies.filter { $0.reference != nil }.count)")
        let coordinator = BenchReplay.makeCoordinator()
        try await BenchDenoise.require()
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        var msPerSeam: [Int] = []
        for copy in inputs.copies {
            guard let audio = copy.audio else {
                if copy.missingRecording { tally.missing += 1; print("SW|missing|\(copy.id)") } else { tally.noRecording += 1; print("SW|no_recording|\(copy.id)") }
                continue
            }
            guard let wav = try? Data(contentsOf: audio), wav.count > 44 else { tally.unreadable += 1; print("SW|unreadable|\(copy.id)"); continue }
            let pcm = wav.subdata(in: 44..<wav.count)
            var offJoins: [Int: ReviewRecord.JoinDecision] = [:]
            let off = await Coordinator.assembleSegments(copy.pieces) { offJoins[$0] = $1 }
            // The rebuilt input must be what live assembly received: for a copy
            // that recorded each segment's delivered text, re-assembly should
            // give the copy's own text (a drift is reported); for an older copy
            // rebuilt from its chunks, anything else is not the live input.
            if off != copy.finalText {
                if copy.reconstructed { tally.unfaithful += 1; print("SW|unfaithful|\(copy.id)"); continue }
                tally.mismatch += 1; print("SW|mismatch|\(copy.id)")
            }
            let reads = await coordinator.readSeams(pieces: copy.pieces, ranges: copy.ranges, pcm: pcm)
            let on = await Coordinator.assembleSegments(copy.pieces, verdicts: reads.verdicts)
            let pauseSeams = copy.pieces.indices.dropFirst().filter { copy.pieces[$0 - 1].sealedBy == .pause }
            let located = pauseSeams.filter { copy.ranges[$0 - 1] != nil && copy.ranges[$0] != nil }.count
            let changed = await Self.changedSeams(pieces: copy.pieces, verdicts: reads.verdicts, baseline: off)
            let marks = reads.verdicts.values
            let wordsChanged = BenchReplay.words(on) != BenchReplay.words(off)
            for (piece, why) in reads.undecided.sorted(by: { $0.key < $1.key }) { print("SW|undecided|\(copy.id)|\(piece)|\(why.rawValue)") }
            var scoredLine = ""
            if let reference = copy.reference {
                let heard = BenchReplay.words(copy.pieces.map(\.text).joined(separator: " "))
                for position in SeamRulesBenchTests.pauseSeamPositions(copy.pieces) {
                    let ref = SeamRulesBenchTests.reading(of: reference, heard: heard, before: position)
                    let wasOff = SeamRulesBenchTests.reading(of: off, heard: heard, before: position)
                    let isOn = SeamRulesBenchTests.reading(of: on, heard: heard, before: position)
                    print("SW|scored|\(copy.id)|\(position)|\(Self.name(ref))|\(Self.name(wasOff))|\(Self.name(isOn))")
                    guard let ref, let wasOff, let isOn else { tally.unscorable += 1; continue }
                    tally.scored += 1
                    switch (wasOff == ref, isOn == ref) {
                    case (false, true): tally.corrected += 1
                    case (true, false): tally.broken += 1
                    case (true, true): tally.sameRight += 1
                    case (false, false): tally.sameWrong += 1
                    }
                }
                scoredLine = "|scored"
            }
            tally.copies += 1
            tally.reviewed += copy.reference == nil ? 0 : 1
            tally.seams += pauseSeams.count
            tally.located += located
            tally.read += reads.verdicts.count + reads.undecided.count
            tally.period += marks.filter { $0 == .period }.count
            tally.comma += marks.filter { $0 == .comma }.count
            tally.nothing += marks.filter { $0 == .nothing }.count
            tally.undecided += reads.undecided.count
            tally.changed += changed
            tally.wordsChanged += wordsChanged ? 1 : 0
            msPerSeam += reads.msPerSeam.values
            print("SW|copy|\(copy.id)|\(copy.reference == nil ? 0 : 1)|\(pauseSeams.count)|\(located)|\(marks.filter { $0 == .period }.count)|\(marks.filter { $0 == .comma }.count)|\(marks.filter { $0 == .nothing }.count)|\(reads.undecided.count)|\(changed)|\(reads.readMs)\(scoredLine)")
        }
        let sorted = msPerSeam.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2], max = sorted.last ?? 0
        print("SW|tally|copies=\(tally.copies) reviewed=\(tally.reviewed) seams=\(tally.seams) located=\(tally.located) read=\(tally.read) period=\(tally.period) comma=\(tally.comma) nothing=\(tally.nothing) undecided=\(tally.undecided) changed=\(tally.changed) words_changed=\(tally.wordsChanged) ms_p50=\(p50) ms_max=\(max) scored=\(tally.scored) corrected=\(tally.corrected) broken=\(tally.broken) same_right=\(tally.sameRight) same_wrong=\(tally.sameWrong) unscorable=\(tally.unscorable) mismatch=\(tally.mismatch) unreadable=\(tally.unreadable) missing=\(tally.missing) no_recording=\(tally.noRecording) gapped=\(tally.gapped) unfaithful=\(tally.unfaithful) cued=\(tally.cued)")
        XCTAssertEqual(tally.wordsChanged, 0, "a seam verdict changed the words of \(tally.wordsChanged) copies")
        XCTAssertEqual(tally.unreadable + tally.missing, 0, "INCOMPLETE: \(tally.unreadable) recordings unreadable, \(tally.missing) named but missing")
    }

    struct Tally {
        var copies = 0, reviewed = 0, seams = 0, located = 0, read = 0, period = 0, comma = 0, nothing = 0, undecided = 0, changed = 0
        var wordsChanged = 0, scored = 0, corrected = 0, broken = 0, sameRight = 0, sameWrong = 0, unscorable = 0, mismatch = 0
        var unreadable = 0, missing = 0, noRecording = 0, gapped = 0, unfaithful = 0, cued = 0

        mutating func count(_ skip: Skip) {
            switch skip {
            case .gapped: gapped += 1
            case .cued: cued += 1
            }
        }
    }

    /// Seams whose verdict changes the assembled TEXT — a verdict that
    /// restates what assembly did (a period over a sentence end, "nothing"
    /// over a breath glue) is not a change (review 2026-09-10, #6).
    static func changedSeams(pieces: [Coordinator.Piece], verdicts: [Int: SeamMark], baseline: String) async -> Int {
        var changed = 0
        for (index, mark) in verdicts where await Coordinator.assembleSegments(pieces, verdicts: [index: mark]) != baseline {
            changed += 1
        }
        return changed
    }

    static func name(_ reading: Reading?) -> String {
        switch reading {
        case .end?: return "end"
        case .clause?: return "clause"
        case .plain?: return "plain"
        case nil: return "-"
        }
    }

    // MARK: - Inputs

    struct CorpusCopy {
        let id: String
        /// The recording beside the copy; nil when none is named (before
        /// recordings were kept) or the named one is gone.
        let audio: URL?
        let missingRecording: Bool
        /// The segments as assembly received them live: each one's delivered text and how it was sealed.
        let pieces: [Coordinator.Piece]
        /// Each piece's PCM range — the live seal points, or derived from lengths while every earlier seal was a pause.
        let ranges: [Range<Int>?]
        let finalText: String
        let reference: String?
        /// The pieces were rebuilt from the chunks (a copy from before schema 6 kept no delivered text).
        let reconstructed: Bool
    }

    /// Why a copy with a pause seam could not be an input — reported, never dropped in silence.
    enum Skip: String { case gapped, cued }

    struct Inputs {
        var copies: [CorpusCopy] = []
        var skipped: [(id: String, why: Skip)] = []
    }

    /// Every copy with a pause seam: with its recording, without one, or
    /// naming one that is gone — nothing disappears from the count
    /// (review 2026-09-10, #7). A copy whose segment indices have a gap (a
    /// segment the recognizer heard nothing in is not recorded, but its
    /// audio and its boundary were real) cannot be rebuilt and is skipped
    /// by name (#4).
    static func corpusInputs(in dir: URL) throws -> Inputs {
        var out = Inputs()
        for copy in LocalReviewStore.copies(in: dir) {
            let record = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Data(contentsOf: copy.url))
            let segments = record.segments.sorted { $0.index < $1.index }
            guard segments.count >= 2, segments.dropLast().contains(where: { $0.boundary == .pause }) else { continue }
            let id = copy.url.lastPathComponent
            // The recording first: a named recording that is gone fails the
            // run whatever else is wrong with the copy (review 2026-09-11, round 2).
            var audio: URL?
            var missing = false
            if let audioName = record.audioFile {
                let url = dir.appending(path: audioName)
                let present = LocalReviewStore.startedAt(ofAudioNamed: audioName) != nil && FileManager.default.fileExists(atPath: url.path)
                if present { audio = url } else { missing = true }
            }
            let (pieces, reconstructed) = Self.pieces(segments: segments, chunks: record.chunks)
            if !missing {
                guard segments.map(\.index) == Array(0..<segments.count) else { out.skipped.append((id, .gapped)); continue }
                // A correction cue crossing a pause makes assembly re-clean both
                // halves with the model: its text is not reproducible run to run,
                // so nothing about that copy is measured.
                guard !pieces.dropFirst().contains(where: { SentenceChunker.opensWithCorrectionCue($0.text) }) else {
                    out.skipped.append((id, .cued)); continue
                }
            }
            out.copies.append(CorpusCopy(id: id, audio: audio, missingRecording: missing, pieces: pieces, ranges: Self.ranges(segments: segments),
                                         finalText: record.finalText, reference: record.reference?.text, reconstructed: reconstructed))
        }
        return out
    }

    /// Each segment's text as assembly received it: the recorded delivered
    /// text (schema 6); for an older copy, its chunks' deliveries joined —
    /// a reconstruction, flagged, that the bench then holds to the copy's
    /// own final text (review 2026-09-10, #5).
    static func pieces(segments: [ReviewRecord.Segment], chunks: [ReviewRecord.Chunk]) -> (pieces: [Coordinator.Piece], reconstructed: Bool) {
        var out: [Coordinator.Piece] = []
        var reconstructed = false
        for segment in segments {
            let text: String
            if let delivered = segment.delivered {
                text = delivered
            } else {
                reconstructed = true
                let own = chunks.filter { $0.segments == [segment.index] }
                text = own.isEmpty ? segment.corrected : own.map(\.delivered).joined(separator: " ")
            }
            let sealedBy: SpeechSegmenter.Reason? = segment.boundary == .pause ? .pause : segment.boundary == .cap ? .cap : nil
            out.append(Coordinator.Piece(text: text, sealedBy: sealedBy))
        }
        return (out, reconstructed)
    }

    /// The live seal points when the copy has them; else the segment lengths
    /// summed while every earlier seal was a pause and no index was skipped
    /// (a cap cut's pre-roll moves the next start by an unknown 200–900 ms;
    /// a skipped segment's audio is unrecorded: unknown from there on).
    static func ranges(segments: [ReviewRecord.Segment]) -> [Range<Int>?] {
        if segments.allSatisfy({ $0.pcmStart != nil && $0.pcmEnd != nil }) {
            return segments.map { $0.pcmStart! ..< $0.pcmEnd! }
        }
        var out: [Range<Int>?] = []
        var start = 0
        var known = true
        var expectedIndex = 0
        for segment in segments {
            guard known, segment.index == expectedIndex, let ms = segment.audioMs else { out.append(nil); known = false; continue }
            let end = start + ms * 32
            out.append(start..<end)
            start = end
            expectedIndex += 1
            if segment.boundary == .cap { known = false }
        }
        return out
    }
}
