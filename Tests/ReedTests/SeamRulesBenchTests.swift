import XCTest
@testable import Reed

/// Seam verdicts measured where it counts (decision 1, narrowed): every
/// human-reviewed copy with a recording and two or more segments is
/// replayed through the live pipeline with the rules off and on, and each
/// pause seam is read in both texts and in the reference — sentence end,
/// clause break, or nothing — by aligning words to what was heard. The
/// bench reports seams the rules corrected, seams they broke, and seams
/// they left; a broken seam fails the bench. Content never reaches the log.
///
/// Gated: REED_SEAM_BENCH=1 swift test --filter SeamRulesBenchTests
///        REED_REVIEW_CORPUS_DIR=<dir>  (default: the app's review directory, as the corpus bench)
///
/// Output lines:
///   SR|copy|<id>|<pause_seams>|<corrected>|<broken>|<same_right>|<same_wrong>|<undecidable>
///   SR|skipped|<id>|<why>          a reviewed copy that could not be replayed (recording missing, unreadable or too short)
///   SR|no_recording|<id>           a reviewed copy from before recordings were kept — reported, not failed
///   SR|failed|<id>|<arm>           a replay arm that failed
///   SR|tally|copies=<n> seams=<n> corrected=<n> broken=<n> same_right=<n> same_wrong=<n> undecidable=<n> skipped=<n> failed=<n> no_recording=<n> unreviewed_with_seams=<n>
/// A skipped or failed reviewed copy fails the bench (INCOMPLETE), as does a
/// broken seam; a run that decided no seam is not a pass.
final class SeamRulesBenchTests: XCTestCase {
    /// How a text reads at a seam.
    enum Reading: Equatable { case end, clause, plain }

    @MainActor
    func testSeamRulesAgainstTheReviewedCorpus() async throws {
        guard ProcessInfo.processInfo.environment["REED_SEAM_BENCH"] == "1" else {
            throw XCTSkip("set REED_SEAM_BENCH=1 to run (replays reviewed copies with seams through the live pipeline)")
        }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else { throw XCTSkip("no Foundation Models") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        let overrideKey = FeatureFlags.overrideKey(for: SeamRules.flag)
        let savedOverride = UserDefaults.standard.object(forKey: overrideKey)
        defer {
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) } else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
            if let savedOverride { UserDefaults.standard.set(savedOverride, forKey: overrideKey) } else { UserDefaults.standard.removeObject(forKey: overrideKey) }
        }
        UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
        XCTAssertEqual(LocalCleanup.tier, .ai)
        let copies = try corpusInputs()
        print("SR|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|reviewed_with_seams=\(copies.filter { $0.reference != nil }.count)|unreviewed_with_seams=\(copies.filter { $0.reference == nil }.count)")
        let coordinator = BenchReplay.makeCoordinator()
        try await BenchDenoise.require()   // denoise proven to run (review 2026-09-08)
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        AICleanup.prewarm()
        var seams = 0, corrected = 0, broken = 0, sameRight = 0, sameWrong = 0, undecidable = 0, scored = 0
        var skipped = 0, failed = 0, noRecording = 0
        for copy in copies {
            guard let reference = copy.reference else { continue }
            guard let audio = copy.audio else {
                if copy.missingRecording { skipped += 1; print("SR|skipped|\(copy.id)|missing") } else { noRecording += 1; print("SR|no_recording|\(copy.id)") }
                continue
            }
            guard let wav = try? Data(contentsOf: audio) else { skipped += 1; print("SR|skipped|\(copy.id)|unreadable"); continue }
            guard wav.count > 44 + 32_000 else { skipped += 1; print("SR|skipped|\(copy.id)|too-short"); continue }
            let pcm = wav.subdata(in: 44..<wav.count)
            var replays: [String: BenchReplay.Result] = [:]
            for arm in ["off", "on"] {
                UserDefaults.standard.set(arm == "on", forKey: overrideKey)
                guard let replay = await BenchReplay.overlapped(pcm, coordinator: coordinator, paced: false), !replay.fellBack else {
                    print("SR|failed|\(copy.id)|\(arm)"); continue
                }
                replays[arm] = replay
            }
            guard let off = replays["off"], let on = replays["on"] else { failed += 1; continue }
            scored += 1
            var c = 0, b = 0, sr = 0, sw = 0, u = 0
            for position in Self.pauseSeamPositions(on.pieces) {
                let heard = Self.words(on.pieces.map(\.text).joined(separator: " "))
                let readings = [("reference", Self.reading(of: reference, heard: heard, before: position)),
                                ("off", Self.reading(of: off.text, heard: heard, before: position)),
                                ("on", Self.reading(of: on.text, heard: heard, before: position))]
                guard let ref = readings[0].1, let wasOff = readings[1].1, let isOn = readings[2].1 else {
                    u += 1
                    print("SR|undecidable|\(copy.id)|\(position)|\(readings.filter { $0.1 == nil }.map(\.0).joined(separator: "+"))")
                    continue
                }
                switch (wasOff == ref, isOn == ref) {
                case (false, true): c += 1
                case (true, false): b += 1
                case (true, true): sr += 1
                case (false, false): sw += 1
                }
            }
            seams += c + b + sr + sw + u; corrected += c; broken += b; sameRight += sr; sameWrong += sw; undecidable += u
            print("SR|copy|\(copy.id)|\(c + b + sr + sw + u)|\(c)|\(b)|\(sr)|\(sw)|\(u)")
        }
        print("SR|tally|copies=\(scored) seams=\(seams) corrected=\(corrected) broken=\(broken) same_right=\(sameRight) same_wrong=\(sameWrong) undecidable=\(undecidable) skipped=\(skipped) failed=\(failed) no_recording=\(noRecording) unreviewed_with_seams=\(copies.filter { $0.reference == nil }.count)")
        XCTAssertEqual(broken, 0, "the rules broke \(broken) seams the rules-off text had right")
        if skipped + failed > 0 {
            XCTFail("INCOMPLETE: \(skipped) reviewed copies could not be replayed, \(failed) failed a replay arm")
        }
    }

    // MARK: - Scoring

    /// Word offsets, into the heard words, of every pause seam.
    static func pauseSeamPositions(_ pieces: [Coordinator.Piece]) -> [Int] {
        var positions: [Int] = []
        var offset = 0
        for (index, piece) in pieces.enumerated() {
            if index > 0, pieces[index - 1].sealedBy == .pause { positions.append(offset) }
            offset += words(piece.text).count
        }
        return positions
    }

    /// How `text` reads right before heard word `position`: the mark on
    /// the text's word aligned to the heard word before the seam. Nil when
    /// that word is not in the text (deleted, or reworded by the reviewer).
    static func reading(of text: String, heard: [String], before position: Int) -> Reading? {
        guard position > 0 else { return nil }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let textWords = tokens.map { words($0).joined() }
        guard let aligned = alignment(heard, textWords)[position - 1] else { return nil }
        let token = tokens[aligned]
        let trailing = token.reversed().prefix { !$0.isLetter && !$0.isNumber }
        if trailing.contains(where: { ".!?…".contains($0) }) { return .end }
        if trailing.contains(where: { ",;:—".contains($0) }) { return .clause }
        return .plain
    }

    /// Longest-common-subsequence alignment: heard index → text index.
    static func alignment(_ a: [String], _ b: [String]) -> [Int: Int] {
        guard !a.isEmpty, !b.isEmpty else { return [:] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [Int: Int] = [:]
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { out[i] = j; i += 1; j += 1 } else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }

    static func words(_ text: String) -> [String] { BenchReplay.words(text) }

    // MARK: - Inputs

    struct CorpusCopy {
        let id: String
        /// The recording beside the copy; nil when the copy names none
        /// (before recordings were kept) or names one that is gone.
        let audio: URL?
        /// The copy names a recording that is not on disk.
        let missingRecording: Bool
        let reference: String?
    }

    /// Every local copy with two or more segments — with its recording,
    /// without one, or naming one that is gone — nothing disappears from
    /// the count (review 2026-09-07). The reference, when a human set one,
    /// is what the seams are scored against.
    func corpusInputs() throws -> [CorpusCopy] {
        let dir = ReviewCorpusBenchTests.corpusDirectory()
        var out: [CorpusCopy] = []
        for copy in LocalReviewStore.copies(in: dir) {
            let record = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Data(contentsOf: copy.url))
            guard record.segments.count >= 2 else { continue }
            var audio: URL?
            var missing = false
            if let audioName = record.audioFile {
                let url = dir.appending(path: audioName)
                let present = LocalReviewStore.startedAt(ofAudioNamed: audioName) != nil && FileManager.default.fileExists(atPath: url.path)
                if present { audio = url } else { missing = true }
            }
            out.append(CorpusCopy(id: copy.url.lastPathComponent, audio: audio, missingRecording: missing, reference: record.reference?.text))
        }
        return out
    }
}

/// The scoring, pinned without models: a seam is read from the text
/// aligned to the heard words, so a reviewer's reworded reference and a
/// collapsed restart still score, and a deleted neighbour is undecidable.
final class SeamRulesScoringTests: XCTestCase {
    private typealias Piece = Coordinator.Piece

    func testASeamIsReadFromTheWordAlignedToTheHeardWordBeforeIt() {
        let pieces = [Piece(text: "If we ship on Friday.", sealedBy: .pause), Piece(text: "We lose the weekend.", sealedBy: .cap),
                      Piece(text: "the weekend and more.", sealedBy: nil)]
        XCTAssertEqual(SeamRulesBenchTests.pauseSeamPositions(pieces), [5], "one pause seam; the cap cut is none")
        let heard = SeamRulesBenchTests.words(pieces.map(\.text).joined(separator: " "))
        XCTAssertEqual(SeamRulesBenchTests.reading(of: "If we ship on Friday. We lose the weekend and more.", heard: heard, before: 5), .end)
        XCTAssertEqual(SeamRulesBenchTests.reading(of: "If we ship on Friday, we lose the weekend and more.", heard: heard, before: 5), .clause)
        XCTAssertEqual(SeamRulesBenchTests.reading(of: "If we ship on Friday we lose the weekend and more.", heard: heard, before: 5), .plain)
        XCTAssertEqual(SeamRulesBenchTests.reading(of: "Shipping Friday, we lose the weekend.", heard: heard, before: 5), .clause, "a reworded reference still aligns on 'Friday'")
        XCTAssertNil(SeamRulesBenchTests.reading(of: "We lose the weekend.", heard: heard, before: 5), "the word before the seam is gone: undecidable")
        XCTAssertNil(SeamRulesBenchTests.reading(of: "anything", heard: heard, before: 0))
    }
}
