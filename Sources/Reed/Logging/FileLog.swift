import Foundation
import OSLog

/// Drop-in replacement for `os.Logger`: every call still reaches Console.app/
/// `log stream` (subsystem "com.local.reed"), and also appends to the single
/// retention-bounded local log file (`FileLog`) that will back a future
/// "send us your logs" report action. Every call site in this codebase is
/// content-free by policy (no transcript/audio/key text), so everything goes
/// out `privacy: .public` — nothing is lost versus the old per-file `Logger`s.
struct Log {
    private let category: String
    private let osLogger: Logger

    init(category: String) {
        self.category = category
        osLogger = Logger(subsystem: "com.local.reed", category: category)
    }

    func debug(_ message: String) {
        osLogger.debug("\(message, privacy: .public)")
        FileLog.append(category: category, level: "DEBUG", message: message)
    }

    func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        FileLog.append(category: category, level: "INFO", message: message)
    }

    /// Matches `os.Logger`'s generic `.log(_:)` (default level) — a few call
    /// sites use it directly rather than picking a specific level.
    func log(_ message: String) {
        osLogger.log("\(message, privacy: .public)")
        FileLog.append(category: category, level: "NOTICE", message: message)
    }

    func notice(_ message: String) {
        osLogger.notice("\(message, privacy: .public)")
        FileLog.append(category: category, level: "NOTICE", message: message)
    }

    func warning(_ message: String) {
        osLogger.warning("\(message, privacy: .public)")
        FileLog.append(category: category, level: "WARN", message: message)
    }

    func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
        FileLog.append(category: category, level: "ERROR", message: message)
    }
}

/// Backs `Log`: serializes all file I/O onto one queue and bounds
/// ~/Library/Application Support/Reed/reed.log to 72h of history, with a
/// size backstop in case a single 72h window produces more than that on its
/// own. Replaces the old per-feature `timings.log`/`correction.log` files,
/// neither of which had real (or, for correction.log, any) retention.
enum FileLog {
    private static let queue = DispatchQueue(label: "com.local.reed.filelog", qos: .utility)

    /// Where the lines land (reed-tests.log in a test process, or the file
    /// the QA runner names — see `resolveFile`).
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Reed", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return resolveFile(in: dir, isTests: KeyStore.isRunningTests, environment: ProcessInfo.processInfo.environment)
    }()

    /// The QA runner's per-run redirect: a test process honours this path
    /// so each QA row's log tripwire judges the lines that run wrote, not
    /// a shared 72-hour file (review 2026-09-04, round 3). The app itself
    /// never honours it.
    static let testLogFileKey = "REED_TEST_LOG_FILE"

    /// The test process shares the app's directory; its fixtures (blocked
    /// hosts, missing models) used to read like a field failure storm in
    /// the app's own log (2026-08-29). Tests get their own file, and a
    /// QA run gets one of its own.
    static func resolveFile(in dir: URL, isTests: Bool, environment: [String: String]) -> URL {
        guard isTests else { return dir.appending(path: "reed.log") }
        if let redirect = environment[testLogFileKey], !redirect.isEmpty {
            return URL(fileURLWithPath: redirect)
        }
        return dir.appending(path: "reed-tests.log")
    }

    private static let stampFormatter = ISO8601DateFormatter()

    /// Past this size, a trim runs before the next append; also the hard
    /// backstop a 72h-age trim falls back to if it isn't enough on its own.
    static let sizeCapBytes = 5_000_000
    static let maxAge: TimeInterval = 72 * 60 * 60

    static func append(category: String, level: String, message: String) {
        let line = "\(stampFormatter.string(from: Date())) [\(category)] \(level): \(message)\n"
        queue.async {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > sizeCapBytes {
                trim()
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Blocks until every append queued so far has been written — for tests
    /// that assert on what did (or did not) reach the file.
    static func waitForPendingWrites() {
        queue.sync {}
    }

    /// Call once at launch — a file that sat untouched while the app was
    /// closed for days needs pruning even though no append triggers it.
    static func trimOnLaunch() {
        queue.async { trim() }
    }

    /// The log's current bytes, for attaching to a "report an issue" submission.
    /// Reads on the same serial queue as every append/trim, so it can't tear a
    /// snapshot mid-write. `fileURL` itself stays private — callers only ever
    /// get content, never the path.
    static func currentSnapshot() -> Data? {
        queue.sync { try? Data(contentsOf: fileURL) }
    }

    private static func trim() {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let survivors = trimmed(lines: lines, now: Date())
        let rewritten = survivors.isEmpty ? "" : survivors.joined(separator: "\n") + "\n"
        try? rewritten.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Pure trim logic, exposed for tests: drop lines older than `maxAge`,
    /// then — if that alone doesn't bring it under `sizeCapBytes` — drop the
    /// oldest survivors until it does. A line without a parseable leading
    /// timestamp is kept rather than silently dropped.
    static func trimmed(lines: [String], now: Date) -> [String] {
        let formatter = ISO8601DateFormatter()
        let cutoff = now.addingTimeInterval(-maxAge)
        var survivors = lines.filter { line in
            guard let spaceIndex = line.firstIndex(of: " "),
                  let stamp = formatter.date(from: String(line[line.startIndex..<spaceIndex]))
            else { return true }
            return stamp >= cutoff
        }
        var totalBytes = survivors.reduce(0) { $0 + $1.utf8.count + 1 }
        while totalBytes > sizeCapBytes, !survivors.isEmpty {
            totalBytes -= survivors.removeFirst().utf8.count + 1
        }
        return survivors
    }
}
