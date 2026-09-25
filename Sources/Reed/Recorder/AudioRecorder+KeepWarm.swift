import AVFoundation
import CoreAudio
import Foundation

private let klog = Log(category: "audio")

/// Keeping a Bluetooth link warm between dictations
/// (design: "Bluetooth · holding the link warm").
///
/// Measured on AirPods: 1855 ms median from hotkey to audible, of which ~1700 ms
/// is macOS switching the device into its call profile. That switch is paid
/// again on every press only because `stop()` tears the stream down. Held open,
/// the same press is ~132 ms.
///
/// Holding is safe because the process is muted at the HAL while held, so the
/// orange indicator stays off and no audio reaches Reed — see `ProcessAudio`.
extension AudioRecorder {
    /// How long a held stream survives without a dictation. Long, deliberately:
    /// starting and stopping the stream is what causes the ~1 s playback
    /// interruption, so a short window would trade the latency win for more
    /// glitches. Ten minutes covers a working session and releases the device
    /// well before it could read as Reed sitting on the mic all day.
    static let keepWarmIdleTimeout: TimeInterval = 600

    /// Whether the stream is being held open between dictations right now.
    var isHoldingWarm: Bool { keepWarmReleaseTask != nil }

    /// Whether the next `start()` can go live essentially immediately, i.e.
    /// the engine is already up. Measured on a pinned USB mic: a resume is
    /// engine 31 ms / first frame 67 ms, while a cold start is engine 751 ms /
    /// first frame 858 ms. The HUD needs this distinction — a second of
    /// "Listening" at a flat waveform is a lie (see `Coordinator.start`).
    var isWarm: Bool { isHoldingWarm || engine.isRunning }

    /// Consecutive above-floor buffers required before real signal counts as
    /// arrived.
    ///
    /// The 3-buffer filter exists to catch the single loud "connect click"
    /// AirPods emit as a link comes up — without it, that click alone would be
    /// mistaken for the mic going live. It applies ONLY to a cold Bluetooth
    /// start: resumed from a hold the link never went down, and wired or
    /// built-in mics have no connect click at all — for them the extra
    /// buffers were ~200 ms of pure self-inflicted cold-start latency
    /// (field, 2026-08-19: wired cold press measured signal at 986 ms, of
    /// which the filter was the last ~200).
    var requiredLoudBuffers: Int {
        if resumedFromWarmHold { return 1 }
        return capturingFromBluetooth ? Self.captureReadyConsecutiveBuffers : 1
    }

    /// Called on release. Holds the stream open (muted) when that will pay off
    /// — Bluetooth (the ~1.7 s SCO switch) or a pinned input (a pin doesn't
    /// survive stop→start; holding keeps it true) — otherwise stops the
    /// engine exactly as before.
    ///
    /// - Returns: true when the stream was held rather than stopped.
    @discardableResult
    func holdWarmOrStop(shouldHold: Bool) -> Bool {
        guard shouldHold, engine.isRunning else {
            stopEngineAndRelease()
            return false
        }
        // Mute FIRST and verify. If the HAL won't guarantee silence, holding
        // would leave a live mic open with no indicator — never do that; fall
        // back to the old teardown, which is merely slow.
        guard ProcessAudio.setInputMuted(true) else {
            klog.error("could not mute at the HAL — stopping the engine instead of holding")
            stopEngineAndRelease()
            return false
        }
        ProcessAudio.allowIdleSleep()
        klog.info("holding input stream warm (muted); engine stays running")
        armWarmHoldRelease()
        return true
    }

    /// Pre-warm from COLD, silently (design: "Onboarding · Done — pre-warmed
    /// try-it"). Mute FIRST — the process must never hold an audible mic it
    /// isn't using — then bring the engine up and keep it up, so a Bluetooth
    /// link pays its ~1.5 s profile switch now, while the user is reading,
    /// instead of eating the front of their first dictation. The next
    /// `start()` resumes from this hold at ~130 ms.
    ///
    /// Every failure path unwinds the mute and leaves the recorder exactly as
    /// the cold path expects — a failed pre-warm costs nothing but the win.
    func beginWarmHold() async {
        guard !isHoldingWarm, !engine.isRunning else { return }
        guard ProcessAudio.setInputMuted(true) else {
            klog.error("pre-warm: HAL mute did not stick — staying cold")
            return
        }
        do {
            try await prewarm(keepRunning: true)
        } catch {
            klog.error("pre-warm failed (\(error.localizedDescription)) — staying cold")
            ProcessAudio.setInputMuted(false)
            return
        }
        guard engine.isRunning else {
            ProcessAudio.setInputMuted(false)
            return
        }
        // A dictation may have JOINED this prewarm during the await and armed
        // capture (race finding, 2026-08-25) — its start() lifted the mute;
        // the stream belongs to it now, so arming a hold here would schedule
        // a release against an active recording.
        guard !bufferQueue.sync(execute: { isCapturing }) else {
            klog.info("pre-warm finished into an active dictation — leaving the stream to it")
            return
        }
        ProcessAudio.allowIdleSleep()
        klog.info("pre-warmed and holding (muted) — first dictation will resume warm")
        armWarmHoldRelease()
    }

    /// The idle-release timer shared by both holds (post-dictation and
    /// pre-warm) — one policy, one implementation.
    private func armWarmHoldRelease() {
        keepWarmReleaseTask?.cancel()
        keepWarmReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.keepWarmIdleTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isHoldingWarm else { return }
                klog.info("keep-warm idle timeout — releasing the device")
                self.releaseWarmHold()
            }
        }
    }

    /// Un-mutes a held stream for a new dictation. Returns true when this press
    /// was served from a held stream and can skip `engine.start()` entirely.
    func resumeFromWarmHold() -> Bool {
        guard isHoldingWarm, engine.isRunning else { return false }
        keepWarmReleaseTask?.cancel()
        keepWarmReleaseTask = nil
        guard ProcessAudio.setInputMuted(false) else {
            // Couldn't unmute: the stream would deliver silence forever, which
            // is the exact dead-mic failure this whole area has been plagued
            // by. Drop the hold and let the normal cold path run.
            klog.error("could not unmute a held stream — falling back to a cold start")
            releaseWarmHold()
            return false
        }
        klog.info("resumed from warm hold — skipping engine start")
        return true
    }

    /// Fully lets go: unmute, stop the engine, release the device. Called on
    /// idle timeout and on every boundary where holding stops making sense —
    /// device change, disconnect, quit.
    func releaseWarmHold() {
        keepWarmReleaseTask?.cancel()
        keepWarmReleaseTask = nil
        stopEngineAndRelease()
    }

    private func stopEngineAndRelease() {
        if engine.isRunning { engine.stop() }
        // Always clear the mute, even when we never set it: leaving a process
        // input-muted would silence the NEXT dictation with no visible cause.
        ProcessAudio.setInputMuted(false)
    }

    /// Installs a direct HAL listener for the default input/output device,
    /// once, for the process's lifetime. Call from `init()`.
    ///
    /// `AVAudioEngineConfigurationChange` does NOT reliably fire for the
    /// case this exists to catch: a pinned input's bound device can drift
    /// onto the process's default-device aggregate with the engine still
    /// running — no stop/start, no notification at all (field log
    /// 2026-08-16: "capture armed from MacBook Pro Microphone" on one
    /// dictation, "capture armed from CADefaultDeviceAggregate-<pid>-N" on
    /// the next, nothing logged in between). A default OUTPUT device change
    /// (e.g. AirPods disconnecting) reconfigures that aggregate even though
    /// the pinned mic itself never changed, and a warm-held (muted) stream
    /// left sitting on it is exposed to coreaudiod tearing the aggregate
    /// down on its own schedule — confirmed as the stuck-indicator cause:
    /// the light came on with zero corresponding lines in Reed's own log,
    /// and stayed on until the next dictation's drift check (`start()`)
    /// happened to fix it. This listener reacts at the moment the default
    /// device changes, instead of waiting for that next press.
    func observeDefaultDeviceChanges() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultDeviceChanged()
        }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    /// Only the idle-hold case is handled here — an active recording is
    /// already covered by the `AVAudioEngineConfigurationChange` handler.
    /// Holding warm on a device the system just reshuffled is the specific
    /// window this closes: release rather than resume-and-hope onto
    /// whatever the aggregate has become. The next press re-pins from
    /// scratch (see the drift check in `start()`), same as any other cold
    /// start.
    private func handleDefaultDeviceChanged() {
        guard isHoldingWarm else { return }
        klog.error("default device changed while holding warm — releasing rather than risk a stuck indicator")
        releaseWarmHold()
    }
}
