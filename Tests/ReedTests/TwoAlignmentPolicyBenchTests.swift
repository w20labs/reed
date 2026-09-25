import XCTest
@testable import Reed

/// Evaluation of one exact mitigation for the slice-start collapse
/// (investigation 2026-09-08), before any production change: recognize
/// every slice twice — as cut, and with 40 ms of −60 dBFS room tone in
/// front — and keep the original unless it holds at most half the words
/// of a second reading of three or more words that is at least two words
/// longer. Failure behavior: a second reading that throws is ignored; a
/// first reading that throws propagates, as today.
///
/// Three stages. The sweep stage takes both readings through the client's
/// piece-level model call and applies `SecondReading.select` itself, so
/// every replacement is visible; the held-out stage counts production's
/// own per-piece selections; the latency stage runs the production path
/// in both arms, the flag off and on, nothing substituted (review
/// 2026-09-08: an earlier version handed cleanup normalized words in the
/// enabled arm, so the arms did different work).
///   sweep    the calibration slices (each tail's start moved back 40…2500 ms,
///            denoised as production does, one piece only) with a known reference — recovered,
///            remaining, and healthy originals the policy replaced (with the
///            replacement's retention against the reference)
///   heldout  every OTHER recording's real app slices (each recorded
///            segment, the tail, the whole take), denoised as production
///            does, through the PRODUCTION path with the flag on, every
///            per-piece selection observed —
///            a long take is decided piece by piece, as production does
///            (review 2026-09-08); replacements are listed as counts
///   latency  the paced replay of every overlapped recording with the
///            policy off and on — the wait after release, end to end
///
/// Gated: REED_POLICY_BENCH=1 swift test --filter TwoAlignmentPolicyBenchTests
///        REED_POLICY_STAGE=sweep|heldout|latency (default: all) · REED_POLICY_ONLY=<copy prefix> · REED_REVIEW_CORPUS_DIR
/// No transcript is ever printed: counts, offsets and timings only.
///
///   PB|sweep|<copy>|<slices>|<collapsed_before>|<recovered>|<remaining>|<healthy_replaced>|<healthy_damaged>
///   PB|replaced|<stage>|<copy>|<slice>|<original_words>|<alternate_words>|<reference_words or ->|<original_found or ->|<alternate_found or ->
///   PB|heldout|<copy>|<slices>|<pieces>|<replaced>|<second_reading_failed>
///   PB|latency|<copy>|<arm>|<segments>|<after_ms>|<words>
///   PB|paired|n=<n> delta_p50=<ms> delta_p90=<ms> delta_max=<ms> delta_min=<ms>   (on − off per recording)
///   PB|tally|sweep_collapsed=<n> recovered=<n> remaining=<n> healthy_replaced=<n> healthy_damaged=<n> heldout_slices=<n> heldout_replaced=<n> latency_off_p50=<ms> latency_on_p50=<ms>
final class TwoAlignmentPolicyBenchTests: XCTestCase {
    struct Reading {
        let original: [String]
        let alternate: [String]?
        let selection: SecondReading.Selection
        var replaced: Bool { selection.replaced }
        var chosen: [String] { BenchReplay.words(selection.text) }
    }

    /// The exact production policy (`SecondReading`) over the client's own
    /// piece-level model call, so the prefixed reading is read as production
    /// reads it — one piece, never re-chunked (review 2026-09-08) — and both
    /// readings are visible.
    static func read(_ pcm: Data) async throws -> Reading {
        var original = "", alternate: String?
        let selection = try await SecondReading.read(pcm, enabled: true) { data in
            let text = try await ParakeetClient.shared.recognizePiece(data)
            if data == pcm { original = text } else { alternate = text }
            return text
        }
        return Reading(original: BenchReplay.words(original), alternate: alternate.map(BenchReplay.words), selection: selection)
    }

    @MainActor
    func testTwoAlignmentPolicy() async throws {
        guard ProcessInfo.processInfo.environment["REED_POLICY_BENCH"] == "1" else {
            throw XCTSkip("set REED_POLICY_BENCH=1 to run (~20 min, real recognizer, local corpus)")
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let stage = ProcessInfo.processInfo.environment["REED_POLICY_STAGE"] ?? "all"
        try await BenchDenoise.require()   // denoise proven to run (review 2026-09-08)
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        let flagKey = FeatureFlags.overrideKey(for: SecondReading.flag)
        let savedFlag = UserDefaults.standard.object(forKey: flagKey)
        defer { if let savedFlag { UserDefaults.standard.set(savedFlag, forKey: flagKey) } else { UserDefaults.standard.removeObject(forKey: flagKey) } }
        UserDefaults.standard.set(false, forKey: flagKey)   // raw readings for the sweep and held-out stages
        print("PB|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|fluidaudio=\(SliceStartSweepBenchTests.fluidAudioVersion())|prefix=\(SecondReading.prefixMs)|min_alt=\(SecondReading.minAlternateWords)|min_gain=\(SecondReading.minGain)")
        let dir = ReviewCorpusBenchTests.corpusDirectory()
        var recordings: [(id: String, pcm: Data, segments: [ReviewRecord.Segment])] = []
        for copy in LocalReviewStore.copies(in: dir) {
            let record = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Data(contentsOf: copy.url))
            guard let audioName = record.audioFile, let wav = try? Data(contentsOf: dir.appending(path: audioName)), wav.count > 44 + 16_000 else { continue }
            recordings.append((String(copy.url.lastPathComponent.prefix(19)), wav.subdata(in: 44..<wav.count), record.segments.sorted { $0.index < $1.index }))
        }
        func tailStart(_ r: (id: String, pcm: Data, segments: [ReviewRecord.Segment])) -> Int? {
            guard r.segments.count >= 2, r.segments.dropLast().last?.boundary == .pause else { return nil }
            let start = r.segments.dropLast().reduce(0) { $0 + ($1.audioMs ?? 0) } * 32
            guard start > 3_500 * 32, r.pcm.count - start > 16_000 else { return nil }
            return start
        }
        var calibration = Set<String>()
        var sweepCollapsed = 0, recovered = 0, remaining = 0, healthyReplaced = 0, healthyDamaged = 0, skippedMultiPiece = 0

        if stage == "all" || stage == "sweep" {
            for r in recordings {
                guard let start = tailStart(r) else { continue }
                let tailWav = await Denoiser.shared.processReporting(wav: BenchReplay.wrap(r.pcm.subdata(in: start..<r.pcm.count)))
                BenchDenoise.assertProcessed(tailWav.outcome, "a tail")
                let expected = BenchReplay.words(try await ParakeetClient.shared.transcribe(wav: tailWav.audio))
                guard expected.count >= 3 else { continue }
                calibration.insert(r.id)
                var slices = 0, before = 0, rec = 0, rem = 0, hr = 0, hd = 0
                for back in stride(from: 40, through: 2_500, by: 40) {
                    let raw = r.pcm.subdata(in: (start - back * 32)..<r.pcm.count)
                    // Production denoises before recognition (review 2026-09-08); a
                    // slice the chunker would cut is not one piece and is skipped.
                    let (denoisedWav, outcome) = await Denoiser.shared.processReporting(wav: BenchReplay.wrap(raw))
                    BenchDenoise.assertProcessed(outcome, "a sweep slice")
                    let slice = denoisedWav.subdata(in: 44..<denoisedWav.count)
                    guard LongAudioChunker.pieces(pcm: slice).count == 1 else { skippedMultiPiece += 1; continue }
                    slices += 1
                    let reading = try await Self.read(slice)
                    let wasCollapsed = SliceStartSweepBenchTests.isCollapse(expected: expected, got: reading.original)
                    let isCollapsed = SliceStartSweepBenchTests.isCollapse(expected: expected, got: reading.chosen)
                    if wasCollapsed { before += 1; if isCollapsed { rem += 1 } else { rec += 1 } }
                    if reading.replaced {
                        let origFound = SeamRulesBenchTests.alignment(expected, reading.original).count
                        let altFound = SeamRulesBenchTests.alignment(expected, reading.chosen).count
                        print("PB|replaced|sweep|\(r.id)|\(back)|\(reading.original.count)|\(reading.alternate?.count ?? -1)|\(expected.count)|\(origFound)|\(altFound)")
                        if !wasCollapsed { hr += 1; if altFound < origFound { hd += 1 } }
                    }
                }
                sweepCollapsed += before; recovered += rec; remaining += rem; healthyReplaced += hr; healthyDamaged += hd
                print("PB|sweep|\(r.id)|\(slices)|\(before)|\(rec)|\(rem)|\(hr)|\(hd)")
            }
        }

        var heldoutSlices = 0, heldoutReplaced = 0
        if stage == "all" || stage == "heldout" {
            if calibration.isEmpty { for r in recordings where tailStart(r) != nil { calibration.insert(r.id) } }
            for r in recordings where !calibration.contains(r.id) {
                var slices: [(String, Data)] = [("whole", r.pcm)]
                var offset = 0
                for segment in r.segments {
                    let length = (segment.audioMs ?? 0) * 32
                    if length > 16_000, offset + length <= r.pcm.count { slices.append(("seg\(segment.index)", r.pcm.subdata(in: offset..<(offset + length)))) }
                    offset += length
                }
                if r.segments.count >= 2, offset < r.pcm.count - 16_000 { slices.append(("tail", r.pcm.subdata(in: offset..<r.pcm.count))) }
                var replaced = 0, failed = 0, pieces = 0
                UserDefaults.standard.set(true, forKey: flagKey)   // the production path decides, piece by piece
                for (name, raw) in slices {
                    // Production denoises before the client sees a slice (review 2026-09-08).
                    let (wav, outcome) = await Denoiser.shared.processReporting(wav: BenchReplay.wrap(raw))
                    BenchDenoise.assertProcessed(outcome, "held-out \(name)")
                    let pcm = wav.subdata(in: 44..<wav.count)
                    var selections: [(SecondReading.Selection, Int)] = []
                    SecondReading.selectionObserver = { selections.append(($0, $1)) }
                    _ = try await ParakeetClient.shared.transcribe(wav: wav)
                    SecondReading.selectionObserver = nil
                    XCTAssertEqual(selections.count, LongAudioChunker.pieces(pcm: pcm).count, "one selection per piece")
                    pieces += selections.count
                    for (selection, bytes) in selections {
                        if selection.alternateWords == nil { failed += 1 }
                        if selection.replaced {
                            replaced += 1
                            print("PB|replaced|heldout|\(r.id)|\(name)/\(bytes / 32)ms|\(selection.originalWords)|\(selection.alternateWords ?? -1)|-|-|-")
                        }
                    }
                }
                UserDefaults.standard.set(false, forKey: flagKey)
                heldoutSlices += slices.count; heldoutReplaced += replaced
                print("PB|heldout|\(r.id)|\(slices.count)|\(pieces)|\(replaced)|\(failed)")
            }
        }

        var offMs: [Int] = [], onMs: [Int] = []
        if stage == "all" || stage == "latency" {
            let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
            defer { if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) } else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) } }
            UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
            if #available(macOS 26.0, *) { AICleanup.prewarm() }
            let coordinator = BenchReplay.makeCoordinator()
            let only = ProcessInfo.processInfo.environment["REED_POLICY_ONLY"]
            var pairs: [(String, Int, Int)] = []
            for r in recordings where r.segments.count >= 2 && (only.map { r.id.hasPrefix($0) } ?? true) {
                var after: [String: Int] = [:]
                for arm in ["off", "on"] {
                    UserDefaults.standard.set(arm == "on", forKey: flagKey)   // the production path, both arms
                    guard let replay = await BenchReplay.overlapped(r.pcm, coordinator: coordinator, paced: true) else { print("PB|latency|\(r.id)|\(arm)|failed"); continue }
                    after[arm] = replay.afterMs
                    if arm == "on" { onMs.append(replay.afterMs) } else { offMs.append(replay.afterMs) }
                    print("PB|latency|\(r.id)|\(arm)|\(replay.segments)|\(replay.afterMs)|\(BenchReplay.words(replay.text).count)")
                }
                if let off = after["off"], let on = after["on"] { pairs.append((r.id, off, on)) }
            }
            let deltas = pairs.map { $0.2 - $0.1 }.sorted()
            if !deltas.isEmpty {
                print("PB|paired|n=\(deltas.count) delta_p50=\(deltas[deltas.count / 2]) delta_p90=\(deltas[min(deltas.count - 1, deltas.count * 9 / 10)]) delta_max=\(deltas.last ?? 0) delta_min=\(deltas.first ?? 0)")
            }
            UserDefaults.standard.set(false, forKey: flagKey)
        }
        SecondReading.selectionObserver = nil
        print("PB|denoise|\(BenchDenoise.tally)")
        print("PB|tally|sweep_collapsed=\(sweepCollapsed) recovered=\(recovered) remaining=\(remaining) healthy_replaced=\(healthyReplaced) healthy_damaged=\(healthyDamaged) skipped_multi_piece=\(skippedMultiPiece) heldout_slices=\(heldoutSlices) heldout_replaced=\(heldoutReplaced) latency_off_p50=\(SliceStartSweepBenchTests.p50(offMs)) latency_on_p50=\(SliceStartSweepBenchTests.p50(onMs))")
    }

}
