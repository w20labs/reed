import Foundation

/// Where review copies live (P16): one JSON file per dictation — and,
/// since 2026-09-06, the recording as a WAV beside it, same name — under
/// `~/Library/Application Support/Reed/Review/`, directory 0700, files
/// 0600, excluded from Time Machine, expired 14 days after the DICTATION —
/// the timestamp in the file's name, never a filesystem date (an atomic
/// rewrite resets the creation time, and a missing one would keep a copy
/// forever; review 2026-09-04 P1). Read and written by nothing in the app
/// but this type; the QA page reads the directory directly. Never part of
/// reed.log, the support report, analytics or crash reports.
enum LocalReviewStore {
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60
    /// The QA runner's per-run redirect for a test process; absent in a test
    /// process means "never write" — a `swift test` run must not drop copies
    /// into the developer's real directory.
    static let directoryEnvKey = "REED_REVIEW_DIR"

    /// nil: this process must not write copies (a test without a redirect).
    static let directory: URL? = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return resolveDirectory(appSupport: appSupport, isTests: KeyStore.isRunningTests,
                                environment: ProcessInfo.processInfo.environment)
    }()

    static func resolveDirectory(appSupport: URL, isTests: Bool, environment: [String: String]) -> URL? {
        if isTests {
            guard let redirect = environment[directoryEnvKey], !redirect.isEmpty else { return nil }
            return URL(fileURLWithPath: redirect, isDirectory: true)
        }
        return appSupport.appending(path: "Reed", directoryHint: .isDirectory)
            .appending(path: "Review", directoryHint: .isDirectory)
    }

    private static let queue = DispatchQueue(label: "com.local.reed.localreview", qos: .utility)
    private static let slog = Log(category: "localreview")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Queue a copy for writing; expiry runs on the same write. Content-free
    /// log line only. `audio` is the dictation's recording (WAV), kept
    /// beside the copy for the corpus bench.
    static func save(_ record: ReviewRecord, audio: Data? = nil) {
        guard let directory else { return }
        queue.async {
            do {
                try write(record, audio: audio, in: directory)
                let removed = expire(in: directory)
                slog.info("review copy written (\(record.counts.chunks) chunks, \(record.segments.count) segments\(audio.map { ", \($0.count / 1024) KB audio" } ?? ""))\(removed.isEmpty ? "" : " · \(removed.count) expired")")
            } catch {
                slog.error("review copy not written: \(error.localizedDescription)")
            }
        }
    }

    /// At launch (P16: "deleted on the next launch or the next write"): a
    /// Mac whose key was removed still sheds its copies on time.
    static func expireOnLaunch() {
        guard let directory else { return }
        queue.async {
            let removed = expire(in: directory)
            if !removed.isEmpty { slog.info("\(removed.count) review copies expired at launch") }
        }
    }

    /// For tests: block until queued writes landed.
    static func waitForPendingWrites() { queue.sync {} }

    /// Write one copy: the directory is created 0700 and excluded from
    /// backups, the file lands 0600 — the audio first, so a copy never names
    /// a recording that is not there. Returns the JSON's URL.
    @discardableResult
    static func write(_ record: ReviewRecord, audio: Data? = nil, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        var record = record
        record.audioFile = nil
        if let audio {
            let audioURL = directory.appending(path: audioFileName(for: record))
            guard FileManager.default.createFile(atPath: audioURL.path, contents: audio, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            record.audioFile = audioURL.lastPathComponent
        }
        let data = try encoder.encode(record)
        let url = directory.appending(path: fileName(for: record))
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    // MARK: - Names carry the dictation's time

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }()

    /// `2026-09-04T22-48-32Z-<id>.json`
    static func fileName(for record: ReviewRecord) -> String {
        "\(stampFormatter.string(from: record.startedAt))-\(record.id).json"
    }

    /// The recording beside it: the same name, `.wav`.
    static func audioFileName(for record: ReviewRecord) -> String {
        "\(stampFormatter.string(from: record.startedAt))-\(record.id).wav"
    }

    /// The dictation's time from a recording's name (`…-<id>.wav`), nil for
    /// anything else — the same exactness as a copy's name.
    static func startedAt(ofAudioNamed name: String) -> Date? {
        guard name.hasSuffix(".wav") else { return nil }
        return startedAt(ofCopyNamed: String(name.dropLast(4)) + ".json")
    }

    /// The dictation's time from a copy's name; nil for anything that is
    /// not EXACTLY a copy's name — a real stamp, a hyphen, a real UUID,
    /// `.json`, nothing else (review 2026-09-05, P2). Such a file is never
    /// touched.
    static func startedAt(ofCopyNamed name: String) -> Date? {
        guard name.count == 20 + 1 + 36 + 5, name.hasSuffix(".json") else { return nil }
        let stamp = String(name.prefix(20))
        let id = String(name.dropFirst(21).dropLast(5))
        guard name.dropFirst(20).first == "-",
              UUID(uuidString: id)?.uuidString.caseInsensitiveCompare(id) == .orderedSame,
              let date = stampFormatter.date(from: stamp), stampFormatter.string(from: date) == stamp
        else { return nil }
        return date
    }

    /// Delete copies whose dictation is older than `maxAge`. Returns what
    /// was removed; a copy that cannot be removed stays and is logged
    /// (never silently counted as gone).
    @discardableResult
    static func expire(in directory: URL, now: Date = Date(), maxAge: TimeInterval = maxAge) -> [URL] {
        var removed: [URL] = []
        // Copies and their recordings on the same clock; a recording whose
        // copy is already gone expires by its own stamp all the same.
        for copy in copies(in: directory) + audioFiles(in: directory) where now.timeIntervalSince(copy.startedAt) > maxAge {
            do {
                try FileManager.default.removeItem(at: copy.url)
                removed.append(copy.url)
            } catch {
                slog.error("expired review copy not removed: \(error.localizedDescription)")
            }
        }
        return removed
    }

    struct Copy: Equatable {
        let url: URL
        let startedAt: Date
    }

    /// Every copy in the directory with its dictation time, oldest first.
    /// A copy is a REGULAR FILE with a copy's name; a directory or link
    /// named like one is not a copy.
    static func copies(in directory: URL) -> [Copy] {
        regularFiles(in: directory).compactMap { url in
            startedAt(ofCopyNamed: url.lastPathComponent).map { Copy(url: url, startedAt: $0) }
        }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Every recording in the directory with its dictation time, oldest first.
    static func audioFiles(in directory: URL) -> [Copy] {
        regularFiles(in: directory).compactMap { url in
            startedAt(ofAudioNamed: url.lastPathComponent).map { Copy(url: url, startedAt: $0) }
        }.sorted { $0.startedAt < $1.startedAt }
    }

    private static func regularFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    struct Inventory: Equatable {
        var count: Int
        var bytes: Int
        /// The oldest copy's dictation time.
        var oldest: Date?
    }

    /// Bytes count the recordings too; the count is copies.
    static func inventory(in directory: URL) -> Inventory {
        let all = copies(in: directory)
        let bytes = (all + audioFiles(in: directory)).reduce(0) { $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return Inventory(count: all.count, bytes: bytes, oldest: all.first?.startedAt)
    }
}
