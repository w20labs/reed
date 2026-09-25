import Foundation

/// Reed makes no first-party network calls of its own: there is no account,
/// no cloud pipeline, no flag or pricing fetch (removed 2026-09-15). What
/// still reaches the network is the speech-model download, Sparkle updates,
/// and the opt-in telemetry SDKs. Enforcement is `GateURLProtocol`, which
/// blocks every host outside its allowlist; this type keeps the error it
/// throws and the per-dictation tally the debug menu and the acceptance
/// test read.
final class NetworkGate {
    static let shared = NetworkGate()

    /// The error a blocked request fails with.
    struct Blocked: LocalizedError {
        let host: String?
        var errorDescription: String? {
            "Reed blocked a request to \(host ?? "?")"
        }
    }

    /// Counts blocked requests for the current dictation session.
    let activity = NetActivity()

    private init() {}
}

/// A tiny thread-safe tally of blocked requests, resettable per dictation
/// session. Surfaced in the hidden debug menu; the acceptance test asserts it
/// stays zero for a session.
final class NetActivity {
    private let lock = NSLock()
    private var blocked = 0

    func reset() {
        lock.lock(); defer { lock.unlock() }
        blocked = 0
    }

    func recordBlocked() {
        lock.lock(); defer { lock.unlock() }
        blocked += 1
    }

    var blockedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return blocked
    }
}
