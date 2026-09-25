import Foundation

/// On-device model storage: the speech model (Parakeet v3, P15) is the one
/// model dictation runs on. FluidAudio owns its files
/// (`ParakeetClient.modelDirectory`); this store adds the "proven to load
/// once" record onboarding gates on, the product-facing name and size, and
/// a test seam. The only other thing here is the one-time removal of the
/// WhisperKit files earlier installs left behind — the engine itself left
/// the repository on 2026-09-06.
enum ModelStore {
    // MARK: The speech model (Parakeet v3 — P15, DECIDED 2026-09-02)

    enum SpeechModel {
        static let name = "Parakeet v3"
        /// Measured on disk for the int8 v3 bundle (2026-09-02).
        static let sizeMB = 461
        static let detail = "Names, jargon and accents, on the Neural Engine. The recognizer behind every dictation."
    }

    /// Test seam: pins both `isSpeechModelInstalled` and `isSpeechModelReady`.
    static var speechModelInstalledOverride: Bool?

    /// The variant dictation runs on.
    static var speechModelVariant: String { ParakeetFlag.variant }

    private static func speechLoadedKey(_ variant: String) -> String { "parakeet.loaded.\(variant)" }

    /// The files are on disk. What launch, dictation and first-run gates ask.
    static var isSpeechModelInstalled: Bool {
        if let override = speechModelInstalledOverride { return override }
        return ParakeetClient.isInstalled(variant: speechModelVariant)
    }

    /// On disk AND proven to load once. What onboarding's Continue asks —
    /// "downloaded" alone lit Continue over a load that never finished
    /// (2026-08-12, the WhisperKit era's lesson, kept).
    static var isSpeechModelReady: Bool {
        if let override = speechModelInstalledOverride { return override }
        return isSpeechModelInstalled && UserDefaults.standard.bool(forKey: speechLoadedKey(speechModelVariant))
    }

    static func markSpeechModelLoaded(variant: String) {
        UserDefaults.standard.set(true, forKey: speechLoadedKey(variant))
    }

    // MARK: Retiring the WhisperKit files (P15 migration)

    static let whisperCleanupKey = "reed.whisperModelsRemoved"
    /// The two variants installs before P15 could hold, and where each
    /// recorded its folder. Kept ONLY so those installs can shed ~600 MB;
    /// nothing loads them (WhisperKit left the repository, 2026-09-06).
    static let legacyWhisperVariants = ["openai_whisper-base", "openai_whisper-large-v3-v20240930_626MB"]
    private static let legacyVariantSelectionKey = "localASRModel"
    private static func legacyFolderKey(_ variant: String) -> String { "localASRFolder.\(variant)" }

    /// ~/Library/Application Support/Reed/Models — the WhisperKit era's
    /// directory; nothing writes there any more.
    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Reed/Models", directoryHint: .isDirectory)
    }

    /// Existing installs carry ~600 MB of WhisperKit models nothing uses
    /// once Parakeet is the engine. Removed once, after the next successful
    /// Parakeet load, and logged — no prompt, no button (P15). `root` and
    /// `defaults` are parameters so the test never touches the real
    /// models directory.
    @discardableResult
    static func removeUnusedWhisperModels(root: URL = modelsDir,
                                          defaults: UserDefaults = .standard) -> [String] {
        // The era's variant selection goes on every call — an install whose
        // file pass was stamped complete before this key was covered still
        // sheds it (review 2026-09-06, P3).
        defaults.removeObject(forKey: legacyVariantSelectionKey)
        guard !defaults.bool(forKey: whisperCleanupKey) else { return [] }
        var removed: [String] = []
        var complete = true
        // A path that survives removal keeps its record and the pass is
        // retried next time (review 2026-09-03, P3: a failed delete used to
        // be reported as removed, forgotten, and stamped done for good).
        func remove(_ path: String, as name: String) {
            do {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                removed.append(name)
            } catch {
                complete = false
                Log(category: "modelstore").error("could not remove \(name): \(error.localizedDescription) — will retry next launch")
            }
        }
        for variant in legacyWhisperVariants {
            let key = legacyFolderKey(variant)
            // Deleted ONLY inside Reed's own models directory: the path is
            // user-writable preference data (finding 2026-08-25).
            if let path = defaults.string(forKey: key), isInside(root: root, path: path),
               FileManager.default.fileExists(atPath: path) {
                remove(path, as: variant)
                if FileManager.default.fileExists(atPath: path) { continue }  // keep the record for the retry
            }
            defaults.removeObject(forKey: key)
        }
        // HubApi's own tree (the tokenizer, download caches) under the root.
        let hub = root.appending(path: "models", directoryHint: .isDirectory)
        if isInside(root: root, path: hub.path), FileManager.default.fileExists(atPath: hub.path) {
            remove(hub.path, as: "models/")
        }
        if complete { defaults.set(true, forKey: whisperCleanupKey) }
        return removed
    }

    /// True when `path` (resolved, symlinks included) lives STRICTLY under
    /// `root`. The root itself is refused (review 2026-08-25): deleting it
    /// would wipe every installed model instead of one.
    static func isInside(root: URL, path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(rootPath + "/")
    }
}
