import XCTest
@testable import Reed

/// P15 (DECIDED 2026-09-02): one speech model. Pins the "installed" versus
/// "ready" distinction onboarding gates on, the test seam, and the one-time
/// retirement of the WhisperKit files on existing installs — the only
/// Whisper thing left in the repository (2026-09-06).
final class SpeechModelStoreTests: XCTestCase {
    override func tearDown() {
        ModelStore.speechModelInstalledOverride = nil
        super.tearDown()
    }

    func testTheOverridePinsBothInstalledAndReady() {
        ModelStore.speechModelInstalledOverride = false
        XCTAssertFalse(ModelStore.isSpeechModelInstalled)
        XCTAssertFalse(ModelStore.isSpeechModelReady)
        ModelStore.speechModelInstalledOverride = true
        XCTAssertTrue(ModelStore.isSpeechModelInstalled)
        XCTAssertTrue(ModelStore.isSpeechModelReady)
    }

    /// Ready is stricter than installed: files on disk that never loaded
    /// must not light onboarding's Continue (the 2026-08-12 lesson, kept).
    func testReadyRequiresAProvenLoadOnTopOfTheFiles() {
        let variant = ModelStore.speechModelVariant
        let key = "parakeet.loaded.\(variant)"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(ModelStore.isSpeechModelReady, "no load record → not ready, whatever is on disk")
        ModelStore.markSpeechModelLoaded(variant: variant)
        XCTAssertEqual(ModelStore.isSpeechModelReady, ModelStore.isSpeechModelInstalled,
                       "with the record, ready follows the files on disk")
    }

    func testTheProductNamesTheModelAndItsSize() {
        XCTAssertEqual(ModelStore.SpeechModel.name, "Parakeet v3")
        XCTAssertEqual(ModelStore.SpeechModel.sizeMB, 461)
        XCTAssertTrue(ParakeetFlag.supportedVariants.contains(ModelStore.speechModelVariant))
    }

    // MARK: retiring the WhisperKit files

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "reed-whisper-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRemovesRecordedVariantFoldersAndTheHubTreeOnce() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reed-tests-\(UUID().uuidString)"))
        // A recorded variant inside the root, and HubApi's tree.
        let variant = ModelStore.legacyWhisperVariants[1]
        let folder = root.appending(path: "models/argmaxinc/whisperkit-coreml/\(variant)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults.set(folder.path, forKey: "localASRFolder.\(variant)")
        defaults.set(variant, forKey: "localASRModel")  // the era's variant selection
        let hub = root.appending(path: "models", directoryHint: .isDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hub.path))

        let removed = ModelStore.removeUnusedWhisperModels(root: root, defaults: defaults)
        XCTAssertEqual(removed, [variant, "models/"])
        XCTAssertNil(defaults.string(forKey: "localASRModel"), "the selection key goes with the files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hub.path))
        XCTAssertNil(defaults.string(forKey: "localASRFolder.\(variant)"), "the record is forgotten with the files")
        XCTAssertTrue(defaults.bool(forKey: ModelStore.whisperCleanupKey))
        // Once: a second call is a no-op even if files reappear (a bench re-fetch).
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        XCTAssertEqual(ModelStore.removeUnusedWhisperModels(root: root, defaults: defaults), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: hub.path), "after the one-time pass the benches' files are left alone")
    }

    /// Review 2026-09-06 (P3): an install whose file pass was stamped
    /// complete before the selection key was covered still sheds it.
    func testTheSelectionKeyGoesEvenWhenTheFilePassWasAlreadyStamped() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reed-tests-\(UUID().uuidString)"))
        defaults.set(true, forKey: ModelStore.whisperCleanupKey)
        defaults.set("openai_whisper-base", forKey: "localASRModel")
        XCTAssertEqual(ModelStore.removeUnusedWhisperModels(root: root, defaults: defaults), [])
        XCTAssertNil(defaults.string(forKey: "localASRModel"))
    }

    /// A removal that fails keeps its record and leaves the pass incomplete,
    /// so the next launch retries it (review 2026-09-03): a failed delete
    /// used to be reported as removed and the one-time key stamped for good.
    func testAFailedRemovalIsRetriedNotForgotten() throws {
        let root = try makeRoot()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reed-tests-\(UUID().uuidString)"))
        let variant = ModelStore.legacyWhisperVariants[0]
        let folder = root.appending(path: "models/argmaxinc/whisperkit-coreml/\(variant)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let locked = folder.appending(path: "weights.bin")
        try Data("x".utf8).write(to: locked)
        // An immutable file makes the directory removal fail with EPERM.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(folder.path, forKey: "localASRFolder.\(variant)")

        let removed = ModelStore.removeUnusedWhisperModels(root: root, defaults: defaults)
        XCTAssertFalse(removed.contains(variant), "a failed delete is not reported as removed")
        XCTAssertNotNil(defaults.string(forKey: "localASRFolder.\(variant)"), "the record survives for the retry")
        XCTAssertFalse(defaults.bool(forKey: ModelStore.whisperCleanupKey), "the pass is not stamped complete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
        // Unlock and retry: now it completes.
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
        XCTAssertTrue(ModelStore.removeUnusedWhisperModels(root: root, defaults: defaults).contains(variant))
        XCTAssertTrue(defaults.bool(forKey: ModelStore.whisperCleanupKey))
    }

    /// The recorded path is user-writable preference data (finding
    /// 2026-08-25): a value pointing outside the root is forgotten, never deleted.
    func testNeverDeletesOutsideTheRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reed-tests-\(UUID().uuidString)"))
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "reed-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        defaults.set(outside.path, forKey: "localASRFolder.\(ModelStore.legacyWhisperVariants[0])")

        let removed = ModelStore.removeUnusedWhisperModels(root: root, defaults: defaults)
        XCTAssertEqual(removed, [], "nothing inside the root to remove")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "an out-of-tree path survives")
        XCTAssertNil(defaults.string(forKey: "localASRFolder.\(ModelStore.legacyWhisperVariants[0])"))
    }
}
