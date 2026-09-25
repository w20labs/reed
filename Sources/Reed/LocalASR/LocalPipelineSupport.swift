import Foundation

/// Guards against a wedged `Denoiser`: `withDeadline` can only abandon the
/// caller's awaiting Task, not the ONNX Runtime call itself, which has no
/// internal suspension point and keeps `Denoiser`'s actor executor occupied
/// even after the timeout fires. Without this, every dictation after a real
/// hang would queue behind the still-running call and pay the full
/// denoise timeout again. Lives outside actor isolation on purpose — it
/// must stay reachable even when the actor itself is wedged. Mirrors the
/// lock pattern `NetActivity` already uses in NetworkGate.swift.
///
/// `internal` (not `private`) so `DenoiseWatchdogTests` can exercise fresh
/// instances directly via `@testable import Reed`.
final class DenoiseWatchdog {
    static let shared = DenoiseWatchdog()

    private let lock = NSLock()
    private var wedged = false

    func isWedged() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return wedged
    }

    func markWedged() {
        lock.lock(); defer { lock.unlock() }
        wedged = true
    }

    /// Test seam: a test that wedges the shared watchdog puts it back.
    func resetForTests() {
        lock.lock(); defer { lock.unlock() }
        wedged = false
    }
}

/// Debug pill timings (design rule ⑩): opt-in per-stage latency line for the
/// Done beat. `defaults write com.local.reed reed.debugTimings -bool YES`.
enum DebugTimings {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "reed.debugTimings") }

    static func line(
        total: Double, load: Double?, denoise: Double? = nil, asr: Double, clean: Double, tier: String,
        engine: String? = nil, warm: Int = 0
    ) -> String {
        var parts: [String] = ["total \(fmt(total))"]
        if let load { parts.append("load \(fmt(load))") }
        if let denoise { parts.append("denoise \(fmt(denoise))") }
        // Which recognizer ran (Parakeet, or "parakeet-loading" while it
        // loads) — "asr 0.2s·parakeet".
        parts.append("asr \(fmt(asr))" + (engine.map { "·\($0)" } ?? ""))
        parts.append("\(tier) \(fmt(clean))")
        // Keep-warm tickles during this hold (lever 6): 0 means the model
        // may have gone cold before the cleanup call.
        if warm > 0 { parts.append("warm \(warm)") }
        return parts.joined(separator: " · ")
    }

    private static func fmt(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }

    private static let timingsLog = Log(category: "timings")

    /// Append a timings line to the consolidated log (numbers only, never
    /// content) — logd on some machines retains nothing from the app, so
    /// Reed owns its latency history via `FileLog`'s 72h-retained file.
    static func persist(_ line: String) {
        timingsLog.notice(line)
    }
}
