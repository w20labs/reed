import Foundation

/// A gate for diagnostics that sit on a hot path: a keyed message is worth
/// logging when it first appears and whenever it changes, never on every
/// repetition. Review 2026-09-04 (P1): the device enumeration runs at
/// UI-tick rate, so a dead device or a failing CoreAudio query logged its
/// rejection about twenty times a second — the same flood the healthy
/// inventory line had just been removed for. `clear` on recovery lets a
/// flapping device log every transition.
final class ChangeOnlyLog: @unchecked Sendable {
    private var last: [String: String] = [:]
    private let lock = NSLock()

    /// True when `message` differs from the last one recorded for `key`
    /// (or nothing was recorded yet); records it either way.
    func shouldLog(key: String, message: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if last[key] == message { return false }
        last[key] = message
        return true
    }

    /// Forget `key` so its next message logs again (the condition cleared).
    func clear(key: String) {
        lock.lock()
        defer { lock.unlock() }
        last[key] = nil
    }
}
