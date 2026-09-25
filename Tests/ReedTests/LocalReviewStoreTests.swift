import XCTest
@testable import Reed

/// P16 (DECIDED 2026-09-04): review copies live in their own directory,
/// 0700/0600, excluded from backups, expired 14 days after the DICTATION
/// (the stamp in the name, never a filesystem date), and a test process
/// never writes into the developer's real directory.
final class LocalReviewStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "reed-review-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    static func record(startedAt: Date = Date(), text: String = "hello world") -> ReviewRecord {
        let review = DictationReview(keepsContent: true, startedAt: startedAt)
        review.segment(0, boundary: .tail, raw: "hello world", corrected: "hello world")
        return review.finish(.init(injection: .init(text: text, target: "org.tabby", method: "ax"),
                                   timings: .init(totalSeconds: 1.0), mode: "localOnly", engine: "parakeet"))
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    func testAWrittenCopyIsPrivateAndExcludedFromBackup() throws {
        let url = try LocalReviewStore.write(Self.record(), in: dir)
        XCTAssertEqual(try permissions(dir), 0o700, "directory must be owner-only")
        XCTAssertEqual(try permissions(url), 0o600, "file must be owner-only")
        let excluded = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "the directory must never ride Time Machine")
        let decoded = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.finalText, "hello world")
        XCTAssertNil(decoded.reference, "a reference is set by a human on the QA page, never by the app")
    }

    func testTheNameCarriesTheDictationsTimeAndOnlyCopiesCount() throws {
        let started = Date(timeIntervalSince1970: 1_788_000_000)
        let record = Self.record(startedAt: started)
        let name = LocalReviewStore.fileName(for: record)
        XCTAssertEqual(name.count, 20 + 1 + 36 + 5, name)
        XCTAssertEqual(LocalReviewStore.startedAt(ofCopyNamed: name), started, "the stamp round-trips (whole seconds)")
        XCTAssertNil(LocalReviewStore.startedAt(ofCopyNamed: "notes.json"))
        XCTAssertNil(LocalReviewStore.startedAt(ofCopyNamed: "2026-08-30T15-20-00Z.txt"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: dir.appending(path: "stray.json"))
        _ = try LocalReviewStore.write(record, in: dir)
        XCTAssertEqual(LocalReviewStore.copies(in: dir).map(\.startedAt), [started], "a stray file is not a copy and is never touched")
        XCTAssertEqual(LocalReviewStore.expire(in: dir, now: started.addingTimeInterval(365 * 86_400)).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "stray.json").path))
    }

    /// Review 2026-09-05 (P2): only a fully formed name on a regular file
    /// is a copy — a parseable stamp in front of anything is not.
    func testOnlyAFullyFormedNameOnARegularFileIsACopy() throws {
        let strays = [
            "2026-09-04T22-48-32Z-" + String(repeating: "-", count: 36) + ".json",   // 36 hyphens is not a UUID
            "2026-09-04T22-48-32Z-notes-from-the-team-kept-here-long.json",         // 36 chars, not a UUID
            "2026-13-04T22-48-32Z-8A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D.json",          // month 13
            "2026-09-04T22-48-32Z-8A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D.json.bak",
            "2026-09-04T22-48-32Z_8A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D.json"           // no hyphen
        ]
        for name in strays { XCTAssertNil(LocalReviewStore.startedAt(ofCopyNamed: name), name) }
        let real = "2026-09-04T22-48-32Z-8A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D.json"
        XCTAssertNotNil(LocalReviewStore.startedAt(ofCopyNamed: real))
        let lowercaseID = String(real.prefix(21)) + real.dropFirst(21).lowercased()
        XCTAssertNotNil(LocalReviewStore.startedAt(ofCopyNamed: lowercaseID), "a lowercase UUID is still a UUID")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in strays { try Data("stray".utf8).write(to: dir.appending(path: name)) }
        // A directory named exactly like a copy is not a copy either.
        try FileManager.default.createDirectory(at: dir.appending(path: real), withIntermediateDirectories: true)
        XCTAssertTrue(LocalReviewStore.copies(in: dir).isEmpty)
        XCTAssertEqual(LocalReviewStore.inventory(in: dir), .init(count: 0, bytes: 0, oldest: nil))
        XCTAssertTrue(LocalReviewStore.expire(in: dir, now: .distantFuture).isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(Set(left), Set(strays + [real]), "nothing was touched")
    }

    func testCopiesOlderThanFourteenDaysExpireAndYoungerOnesStay() throws {
        let old = try LocalReviewStore.write(Self.record(startedAt: Date(timeIntervalSinceNow: -15 * 86_400), text: "old"), in: dir)
        let young = try LocalReviewStore.write(Self.record(text: "young"), in: dir)
        XCTAssertEqual(names(LocalReviewStore.expire(in: dir)), names([old]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: young.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        // Exactly at the edge is kept; a second past it goes.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let edge = try LocalReviewStore.write(Self.record(startedAt: now.addingTimeInterval(-LocalReviewStore.maxAge), text: "edge"), in: dir)
        XCTAssertTrue(LocalReviewStore.expire(in: dir, now: now).isEmpty)
        XCTAssertEqual(names(LocalReviewStore.expire(in: dir, now: now.addingTimeInterval(1))), names([edge]))
    }

    /// The QA page rewrites a copy to add the reference — even atomically
    /// (a new inode, a new creation date). The dictation's time in the name
    /// is what expiry reads, so no rewrite can extend a copy's life
    /// (review 2026-09-04, P1).
    func testAnAtomicRewriteDoesNotExtendACopysLife() throws {
        let url = try LocalReviewStore.write(Self.record(startedAt: Date(timeIntervalSinceNow: -15 * 86_400), text: "reviewed"), in: dir)
        try Data("rewritten atomically".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(names(LocalReviewStore.expire(in: dir)), names([url]))
    }

    func testInventoryCountsBytesAndTheOldestDictation() throws {
        XCTAssertEqual(LocalReviewStore.inventory(in: dir), .init(count: 0, bytes: 0, oldest: nil))
        let older = Date(timeIntervalSinceNow: -3 * 86_400)
        _ = try LocalReviewStore.write(Self.record(startedAt: older, text: "a"), in: dir)
        _ = try LocalReviewStore.write(Self.record(text: "b"), in: dir)
        let inv = LocalReviewStore.inventory(in: dir)
        XCTAssertEqual(inv.count, 2)
        XCTAssertGreaterThan(inv.bytes, 0)
        XCTAssertEqual(inv.oldest.map { Int($0.timeIntervalSince1970) }, Int(older.timeIntervalSince1970))
    }

    func testATestProcessNeverWritesIntoTheRealDirectory() {
        let appSupport = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        XCTAssertNil(LocalReviewStore.resolveDirectory(appSupport: appSupport, isTests: true, environment: [:]))
        XCTAssertNil(LocalReviewStore.resolveDirectory(appSupport: appSupport, isTests: true, environment: [LocalReviewStore.directoryEnvKey: ""]))
        XCTAssertEqual(LocalReviewStore.resolveDirectory(appSupport: appSupport, isTests: true,
                                                         environment: [LocalReviewStore.directoryEnvKey: "/tmp/qa/review"])?.path, "/tmp/qa/review")
        XCTAssertEqual(LocalReviewStore.resolveDirectory(appSupport: appSupport, isTests: false,
                                                         environment: [LocalReviewStore.directoryEnvKey: "/tmp/elsewhere"])?.path,
                       "/Users/someone/Library/Application Support/Reed/Review", "the app ignores the redirect")
        XCTAssertNil(LocalReviewStore.directory, "this test process has no redirect, so it must write nowhere")
    }

    func testSaveWithoutADirectoryWritesNothing() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Reed/Review", directoryHint: .isDirectory)
        let record = Self.record()
        LocalReviewStore.save(record)
        LocalReviewStore.waitForPendingWrites()
        let after = names(LocalReviewStore.copies(in: real).map(\.url))
        XCTAssertFalse(after.contains(LocalReviewStore.fileName(for: record)), "a test wrote into the developer's real review directory")
    }

    // MARK: - The recording beside the copy (2026-09-06)

    func testTheRecordingIsWrittenBesideTheCopyPrivateAndNamedInIt() throws {
        let record = Self.record()
        let url = try LocalReviewStore.write(record, audio: Data(repeating: 7, count: 1_000), in: dir)
        let audio = dir.appending(path: LocalReviewStore.audioFileName(for: record))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try permissions(audio), 0o600, "the recording is owner-only too")
        let decoded = try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.audioFile, audio.lastPathComponent, "the copy names its recording")
        XCTAssertEqual(LocalReviewStore.startedAt(ofAudioNamed: audio.lastPathComponent), LocalReviewStore.startedAt(ofCopyNamed: url.lastPathComponent))
        XCTAssertEqual(LocalReviewStore.inventory(in: dir).bytes, 1_000 + (try Data(contentsOf: url)).count, "bytes count the recording")
        XCTAssertEqual(LocalReviewStore.inventory(in: dir).count, 1, "the count is copies")
        // Without audio the copy says so.
        let plain = try LocalReviewStore.write(Self.record(startedAt: Date().addingTimeInterval(-60)), in: dir)
        XCTAssertNil(try LocalReviewStore.decoder.decode(ReviewRecord.self, from: Data(contentsOf: plain)).audioFile)
    }

    func testTheRecordingExpiresWithItsCopyAndOnItsOwn() throws {
        let old = Date(timeIntervalSince1970: 1_788_000_000)
        let record = Self.record(startedAt: old)
        let url = try LocalReviewStore.write(record, audio: Data(count: 10), in: dir)
        let audio = dir.appending(path: LocalReviewStore.audioFileName(for: record))
        // An orphaned recording (its copy deleted by hand) still expires by its stamp.
        let orphan = dir.appending(path: LocalReviewStore.audioFileName(for: Self.record(startedAt: old.addingTimeInterval(1))))
        try Data(count: 10).write(to: orphan)
        let removed = LocalReviewStore.expire(in: dir, now: old.addingTimeInterval(15 * 86_400))
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), Set([url, audio, orphan].map(\.lastPathComponent)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testAStrayWavIsNotARecording() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["notes.wav", "2026-09-04T22-48-32Z-notes-from-the-team-kept-here-long.wav"] {
            try Data(count: 10).write(to: dir.appending(path: name))
            XCTAssertNil(LocalReviewStore.startedAt(ofAudioNamed: name), name)
        }
        XCTAssertTrue(LocalReviewStore.audioFiles(in: dir).isEmpty)
        XCTAssertTrue(LocalReviewStore.expire(in: dir, now: .distantFuture).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2, "nothing was touched")
    }
}
