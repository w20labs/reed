import XCTest
@testable import Reed

/// The review corpus, replayed (2026-09-06): every REVIEWED local copy
/// that kept its recording goes through the live pipeline again — the
/// segmenter at real-time pace, Parakeet, the cleanup tier, assembly — and
/// the text that comes out is scored against the human reference. This is
/// the end-to-end regression the text-only copies could not give: a
/// recognizer or seam change shows up here, on the developer's own speech.
///
/// Gated: REED_REVIEW_BENCH=1 swift test --filter ReviewCorpusBenchTests
///        REED_REVIEW_CORPUS_DIR=<dir>  (default: the app's review directory)
///        REED_REVIEW_PACE=0            replay faster than real time (latency numbers meaningless)
/// Lines are CONTENT-FREE (review 2026-09-07: the QA log and its archive are
/// ordinary files outside the corpus's permissions and expiry):
///        RC|<copy id>|<ned>|<exact>|<after_release_ms>|<reference words>|<produced words>
///        RC|tally|copies=<reviewed> replayed=<n> mean_ned=<x> exact=<n> no_recording=<n> missing=<n> unusable=<n> fallback=<n> failed=<n>
/// Every reviewed copy counts: one that names a recording that is not
/// there, or whose recording is too short to replay, makes the run
/// INCOMPLETE and fails it; a copy from before recordings were kept is
/// reported, not failed. A corpus with nothing to replay fails too.
final class ReviewCorpusBenchTests: XCTestCase {
    struct Copy: Equatable {
        enum Recording: Equatable {
            case present(URL)
            /// A copy written before recordings were kept (schema < 4).
            case none
            /// The copy names a recording that is not on disk.
            case missing(String)
        }
        let id: String
        let reference: String
        let recording: Recording
    }

    static func corpusDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["REED_REVIEW_CORPUS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Reed/Review", directoryHint: .isDirectory)
    }

    /// Every reviewed copy, oldest first, with what it has for a recording.
    static func reviewedCopies(in directory: URL) throws -> [Copy] {
        var out: [Copy] = []
        for copy in LocalReviewStore.copies(in: directory) {
            let record = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Data(contentsOf: copy.url))
            guard let reference = record.reference?.text else { continue }
            let recording: Copy.Recording
            if let audioName = record.audioFile {
                let audio = directory.appending(path: audioName)
                let present = LocalReviewStore.startedAt(ofAudioNamed: audioName) != nil && FileManager.default.fileExists(atPath: audio.path)
                recording = present ? .present(audio) : .missing(audioName)
            } else {
                recording = .none
            }
            out.append(Copy(id: copy.url.lastPathComponent, reference: reference, recording: recording))
        }
        return out
    }

    @MainActor
    func testReviewedCopiesReplayedAgainstTheirReferences() async throws {
        guard ProcessInfo.processInfo.environment["REED_REVIEW_BENCH"] == "1" else {
            throw XCTSkip("set REED_REVIEW_BENCH=1 to run (replays the review corpus through the real pipeline)")
        }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else { throw XCTSkip("no Foundation Models") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let directory = Self.corpusDirectory()
        let copies = try Self.reviewedCopies(in: directory)
        print("RC|env|\(ProcessInfo.processInfo.operatingSystemVersionString)|dir=\(directory.path)|copies=\(copies.count)")
        guard copies.contains(where: { if case .present = $0.recording { return true } else { return false } }) else {
            XCTFail("no reviewed copy with a recording in \(directory.path) — review some dictations on the QA page first")
            return
        }
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
        defer {
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let paced = ProcessInfo.processInfo.environment["REED_REVIEW_PACE"] != "0"
        let coordinator = BenchReplay.makeCoordinator()
        try await BenchDenoise.require()   // denoise proven to run (review 2026-09-08)
        try await BenchStage.run("parakeet prepare") { try await ParakeetClient.shared.prepare() }
        AICleanup.prewarm()
        var distances: [Double] = []
        var exact = 0, noRecording = 0, missing = 0, unusable = 0, fallback = 0, failed = 0
        for copy in copies {
            guard case .present(let audio) = copy.recording else {
                if case .missing = copy.recording { missing += 1 } else { noRecording += 1 }
                continue
            }
            let wav = try Data(contentsOf: audio)
            guard wav.count > 44 else { unusable += 1; continue }
            let pcm = wav.subdata(in: 44..<wav.count)
            // A recognizer failure is the app's single-pass fallback, scored as
            // what the app would deliver; a failure of that too is a failed copy.
            guard let replay = await BenchReplay.overlapped(pcm, coordinator: coordinator, paced: paced) else { failed += 1; continue }
            if replay.fellBack { fallback += 1 }
            let produced = replay.text, after = replay.afterMs
            let ned = BenchReplay.normalizedEditDistance(produced, reference: copy.reference)
            let same = BenchReplay.words(produced) == BenchReplay.words(copy.reference)
            if same { exact += 1 }
            distances.append(ned)
            print(Self.line(copy: copy.id, ned: ned, exact: same, afterMs: after, reference: copy.reference, produced: produced))
        }
        let mean = distances.isEmpty ? 1.0 : distances.reduce(0, +) / Double(distances.count)
        print("RC|tally|copies=\(copies.count) replayed=\(distances.count) mean_ned=\(String(format: "%.3f", mean)) exact=\(exact) no_recording=\(noRecording) missing=\(missing) unusable=\(unusable) fallback=\(fallback) failed=\(failed)")
        XCTAssertFalse(distances.isEmpty, "nothing replayed")
        if missing + unusable + failed > 0 {
            XCTFail("INCOMPLETE: \(missing) reviewed copies name a recording that is not there, \(unusable) recordings are too short to replay, \(failed) failed even single-pass")
        }
    }

    /// The per-copy log line — CONTENT-FREE: the QA log and its archive are
    /// ordinary files outside the corpus's permissions and expiry, so the
    /// words stay in the corpus and only counts leave it.
    static func line(copy: String, ned: Double, exact: Bool, afterMs: Int, reference: String, produced: String) -> String {
        "RC|\(copy)|\(String(format: "%.3f", ned))|\(exact)|\(afterMs)|\(BenchReplay.words(reference).count)|\(BenchReplay.words(produced).count)"
    }

    // MARK: - The pieces, without a model

    /// Review 2026-09-07 (round 2): the replay is the app's press — measured
    /// levels feed the silence-artifact filter, a recognizer failure takes
    /// the single-pass fallback, and a failure of that too is nil, never
    /// placeholder text.
    @MainActor
    func testReplayUsesMeasuredLevelsFallsBackAndNeverInventsText() async {
        let coordinator = BenchReplay.makeCoordinator()
        defer { Coordinator.transcribeOverride = nil }
        let silence = Data(count: 16_000 * 2)   // one second of digital silence
        // The recognizer "hears" a pleasantry in silence: the artifact filter
        // drops it at the measured level, exactly as the app would.
        Coordinator.transcribeOverride = { _ in "Thank you." }
        let quiet = await BenchReplay.overlapped(silence, coordinator: coordinator, paced: false)
        XCTAssertEqual(quiet?.text, "", "silence plus a hallucinated pleasantry is nothing to type")
        XCTAssertEqual(quiet?.fellBack, false)
        // Every recognition fails: single-pass fails too — nil, not "<nil>".
        Coordinator.transcribeOverride = { _ in throw Boom() }
        let failed = await BenchReplay.overlapped(silence, coordinator: coordinator, paced: false)
        XCTAssertNil(failed)
        // Only the overlapped pass fails: the take comes through single-pass, as in production.
        let calls = Counter()
        Coordinator.transcribeOverride = { _ in if await calls.next() == 1 { throw Boom() }; return "hello there" }
        let recovered = await BenchReplay.overlapped(Data(repeating: 0x40, count: 16_000 * 2), coordinator: coordinator, paced: false)
        XCTAssertEqual(recovered?.fellBack, true)
        XCTAssertEqual(recovered?.segments, 1)
        XCTAssertFalse(recovered?.text.isEmpty ?? true)
    }

    /// The level handed to the artifact filter is the one the app hands it:
    /// each head its own slice, the tail and the fallback the WHOLE
    /// recording (`recorder.lastRecordingRMSdB`). A loud head and a silent
    /// tail: the app keeps a pleasantry heard in the tail (the recording is
    /// loud); a bench that meters the tail alone drops it (review 2026-09-07).
    @MainActor
    func testTheTailAndTheFallbackCarryTheRecordingsLevelLikeTheApp() async {
        let coordinator = BenchReplay.makeCoordinator()
        defer { Coordinator.transcribeOverride = nil }
        let pcm = Self.loudHeadSilentTail()
        XCTAssertLessThan(LongAudioChunker.rmsDB(pcm.suffix(1_500 * 32)), SilenceArtifact.maxPlausibleRMSdB)
        XCTAssertGreaterThan(RecordingLevels.measure(pcm: pcm).rmsDB, SilenceArtifact.maxPlausibleRMSdB)
        Coordinator.transcribeOverride = { wav in wav.count > 2_000 * 32 ? "hello there" : "Thank you." }
        let replay = await BenchReplay.overlapped(pcm, coordinator: coordinator, paced: false)
        XCTAssertEqual(replay?.segments, 2, "the head must seal at the pause for this to test anything")
        XCTAssertEqual(replay?.fellBack, false)
        XCTAssertTrue(replay?.text.lowercased().contains("thank you") ?? false, "the tail's pleasantry is kept at the recording's level: \(replay?.text ?? "nil")")
        // Same recording through the fallback: the head fails, the tail
        // succeeds, single-pass on the whole take carries its level too.
        Coordinator.transcribeOverride = { wav in
            if wav.count > 4_000 * 32 { return "Thank you." }
            if wav.count > 2_000 * 32 { throw Boom() }
            return "Thank you."
        }
        let fallen = await BenchReplay.overlapped(pcm, coordinator: coordinator, paced: false)
        XCTAssertEqual(fallen?.fellBack, true)
        XCTAssertTrue(fallen?.text.lowercased().contains("thank you") ?? false, "single-pass keeps it at the recording's level: \(fallen?.text ?? "nil")")
    }

    /// A failed tail falls back at once. The app's release path short-
    /// circuits (`guard let tail, let heads = await collect()`); a helper
    /// that awaits the heads regardless hangs on a stuck worker and charges
    /// a slow one to the fallback's latency (review 2026-09-07).
    @MainActor
    func testAFailedTailFallsBackWithoutWaitingForTheHeads() async {
        let coordinator = BenchReplay.makeCoordinator()
        defer { Coordinator.transcribeOverride = nil }
        let pcm = Self.loudHeadSilentTail()
        let gate = Gate(), seen = Counter()
        Coordinator.transcribeOverride = { wav in
            if wav.count > 4_000 * 32 { _ = await seen.next(); return "recovered" }   // single-pass on the whole take
            if wav.count > 2_000 * 32 { await gate.wait(); return "parked head" }
            throw Boom()                                                              // the tail
        }
        let replay = Task { @MainActor in await BenchReplay.overlapped(pcm, coordinator: coordinator, paced: false) }
        let deadline = Date().addingTimeInterval(5)
        while await seen.value == 0, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        let fellBackWhileParked = await seen.value == 1
        await gate.open()
        let result = await replay.value
        XCTAssertTrue(fellBackWhileParked, "single-pass must start while the head is still parked")
        XCTAssertEqual(result?.fellBack, true)
        XCTAssertEqual(result?.text.lowercased().contains("recovered"), true)
    }

    private struct Boom: Error {}

    /// 300 ms of room tone, 2.5 s of loud noise, 1.5 s of room tone: the
    /// segmenter seals the speech at the pause (≥ 2 s spoken, ≥ 700 ms
    /// silence), leaving a silent tail on a loud recording.
    private static func loudHeadSilentTail() -> Data {
        var seed: UInt32 = 12_345
        func noise(ms: Int, amplitude: Int16) -> [Int16] {
            (0..<(ms * 16)).map { _ in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return Int16(truncatingIfNeeded: Int(seed >> 16) % (2 * Int(amplitude) + 1) - Int(amplitude))
            }
        }
        let samples = noise(ms: 300, amplitude: 40) + noise(ms: 2_500, amplitude: 14_000) + noise(ms: 1_500, amplitude: 40)
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
    }

    private actor Counter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }

    func testTheLogLineCarriesCountsNeverWords() {
        let line = Self.line(copy: "x.json", ned: 0.25, exact: false, afterMs: 120,
                             reference: "Never share it outside the team.", produced: "Never share it outside the team, please.")
        XCTAssertEqual(line, "RC|x.json|0.250|false|120|6|7")
        for word in ["never", "share", "team", "please"] { XCTAssertFalse(line.lowercased().contains(word), word) }
    }

    /// Every reviewed copy is in the corpus, classified: with its recording,
    /// from before recordings were kept, or naming one that is gone —
    /// nothing disappears from the count (review 2026-09-07).
    func testEveryReviewedCopyIsInTheCorpusWithItsRecordingState() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "reed-corpus-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        func reviewed(_ offset: TimeInterval, _ text: String) -> ReviewRecord {
            var record = LocalReviewStoreTests.record(startedAt: Date(timeIntervalSince1970: 1_788_000_000 + offset), text: text)
            record.reference = .init(text: text.capitalized + ".", setBy: "human", setAt: Date(), edited: true)
            return record
        }
        let one = reviewed(0, "one"), three = reviewed(200, "three"), four = reviewed(300, "four")
        let present = try LocalReviewStore.write(one, audio: Data(count: 100), in: dir)
        _ = try LocalReviewStore.write(LocalReviewStoreTests.record(startedAt: Date(timeIntervalSince1970: 1_788_000_100), text: "two"), audio: Data(count: 100), in: dir)   // not reviewed
        let none = try LocalReviewStore.write(three, in: dir)
        let gone = try LocalReviewStore.write(four, audio: Data(count: 100), in: dir)
        try FileManager.default.removeItem(at: dir.appending(path: LocalReviewStore.audioFileName(for: four)))
        let corpus = try Self.reviewedCopies(in: dir)
        XCTAssertEqual(corpus.map(\.id), [present, none, gone].map(\.lastPathComponent))
        XCTAssertEqual(corpus[0].recording, .present(dir.appending(path: LocalReviewStore.audioFileName(for: one))))
        XCTAssertEqual(corpus[1].recording, .none)
        XCTAssertEqual(corpus[2].recording, .missing(LocalReviewStore.audioFileName(for: four)))
        XCTAssertEqual(corpus[0].reference, "One.")
    }

    func testTheEditDistanceIsWordLevelAndNormalised() {
        XCTAssertEqual(BenchReplay.normalizedEditDistance("Tell me what you think.", reference: "tell me what you think"), 0)
        XCTAssertEqual(BenchReplay.normalizedEditDistance("tell me tell me what you think", reference: "tell me what you think"), 0.4, accuracy: 0.001)
        XCTAssertEqual(BenchReplay.normalizedEditDistance("", reference: "a b"), 1)
    }
}
