import Foundation

/// Warm-up measurement for the Bluetooth latency work.
///
/// The complaint being chased is "AirPods make me wait ~2 s on every press".
/// Before changing anything, the wait has to be attributed: how much is the
/// engine starting, how much is the tap arriving, and how much is the
/// Bluetooth link actually becoming audible. Only the last is what the user
/// feels, and only it should be optimised.
///
/// One line per press, appended to the same `timings.log` the rest of the
/// pipeline uses. Numbers only, never content.
extension Coordinator {
    /// Emitted when real signal arrives — the press "succeeded".
    func logWarmupSucceeded() {
        let signalAt = Date()
        persistWarmup(signalAt: signalAt, outcome: "ok")
        // First-ever dictation: capture the two facts that decide whether Reed
        // felt like magic (transport + time-to-audio). Local-only until the
        // user consents to telemetry — see FirstDictation.
        if let device = currentInputDevice, let ms = recorder.warmMillis(to: signalAt) {
            FirstDictation.recordIfFirst(transport: device.transport, timeToAudioMs: ms)
        }
    }

    /// Emitted when the recording ends without real signal ever arriving:
    /// the user released early, or the device never became audible at all.
    /// Logging only the successes would make the average look far better than
    /// the experience actually is.
    func logWarmupAbandoned() {
        persistWarmup(signalAt: nil, outcome: "no-signal")
    }

    private func persistWarmup(signalAt: Date?, outcome: String) {
        guard recorder.warmPressedAt != nil else { return }
        let engine = recorder.warmMillis(to: recorder.warmEngineStartedAt)
        let frame = recorder.warmMillis(to: recorder.warmFirstFrameAt)
        let signal = recorder.warmMillis(to: signalAt)
        // `warm=1` means the engine was already running when this press
        // started — the state a keep-warm scheme would create, so these lines
        // are directly comparable before and after any such change.
        let line = String(
            format: "MIC warmup %@ bt=%d warm=%d engine=%@ frame=%@ signal=%@ rate=%.0f",
            outcome,
            currentMicIsBluetooth ? 1 : 0,
            recorder.warmEngineWasRunning ? 1 : 0,
            engine.map { "\($0)ms" } ?? "-",
            frame.map { "\($0)ms" } ?? "-",
            signal.map { "\($0)ms" } ?? "-",
            recorder.warmSampleRate
        )
        log.notice("\(line)")
        DebugTimings.persist(line)
    }
}
