import Foundation

/// Keep the on-device cleanup model hot for the whole hold (lever 6,
/// 2026-08-28). Measured: the Foundation Model goes cold after ~5 s without
/// a call and charges ~870 ms on the next — so every dictation longer than
/// a breath paid it at release, on the stage that is already the wait.
/// Recognition has no such penalty. A one-token call every `interval` from
/// press to release keeps cleanup at its warm floor (~610 ms); the cost is
/// GPU time the user never waits for. Overlapped segments keep the model
/// busy on their own, but the loop is cheap and covers the gaps.
///
/// Flag `cleanup_keepwarm`, default ON. AI tier only.
extension Coordinator {
    static let keepWarmFlag = "cleanup_keepwarm"
    /// Under the ~5 s cold-off, with margin for a tickle queued behind a
    /// segment cleanup (the model serializes calls).
    static let keepWarmInterval: TimeInterval = 3.0

    /// The recognizer a dictation just used, for the timings line.
    var engineLabel: String {
        ParakeetClient.isReady ? "parakeet" : "parakeet-loading"
    }

    /// Called at recording start. Idempotent per press.
    func startKeepWarm() {
        stopKeepWarm()
        keepWarmTickles = 0
        guard LocalCleanup.tier == .ai,
              FeatureFlags.shared.isEnabled(Self.keepWarmFlag, default: true) else { return }
        keepWarmTask = Task { @MainActor in
            while !Task.isCancelled {
                if #available(macOS 26.0, *) { await AICleanup.tickle() }
                keepWarmTickles += 1
                try? await Task.sleep(nanoseconds: UInt64(Self.keepWarmInterval * 1_000_000_000))
            }
        }
    }

    /// Called on release and cancel, BEFORE the release-path cleanup so no
    /// tickle queues ahead of it.
    func stopKeepWarm() {
        keepWarmTask?.cancel()
        keepWarmTask = nil
    }
}
