import AppKit
import KeyboardShortcuts

/// Hands-free dictation (P17, DECIDED 2026-10-11; design: Using Reed › HUD ·
/// hands-free): double-tap the shortcut to lock the mic, tap to finish, Esc to
/// discard — plus the five-minute limit every press now finishes at instead of
/// silently dropping audio past it.
extension Coordinator {
    /// The recorder keeps five minutes of audio (`maxRecordingBytes`, 16 kHz
    /// mono int16); a press finishes there rather than lose what follows.
    static let recordingLimit = TimeInterval(AudioRecorder.maxRecordingBytes) / 32_000
    /// "30 s left" shows this long before the limit.
    static let recordingLimitWarningLead: TimeInterval = 30

    /// A locked session whose capture is still live. The hold monitor reads
    /// this at every event, so a session that ended any other way is never
    /// mistaken for a live one.
    var isHandsFreeLive: Bool { handsFree && isCaptureLive }

    /// The press still owns a live capture. Warming counts: a capture retry
    /// (handleCaptureInterrupted) passes back through it mid-press, and the
    /// one definition keeps every hands-free rule from mistaking that for
    /// the end of the press (review 2026-10-11).
    var isCaptureLive: Bool {
        switch state {
        case .warming, .recording: return true
        default: return false
        }
    }

    /// Wire the hold monitor's hands-free events, each through a main-actor
    /// Task like onStart. `onLock` only ever follows a start that went out at
    /// least one press earlier; a lock with no capture yet arrives as
    /// `onStartLocked`, one call, so nothing depends on two Tasks' order.
    func configureHandsFree() {
        holdMonitor.isLocked = { [weak self] in self?.isHandsFreeLive ?? false }
        holdMonitor.onLock = { [weak self] in
            Task { @MainActor in self?.lockHandsFree() }
        }
        holdMonitor.onStartLocked = { [weak self] in
            Task { @MainActor in await self?.start(handsFree: true) }
        }
        holdMonitor.onFinish = { [weak self] in
            Task { @MainActor in await self?.stopAndProcess() }
        }
        holdMonitor.onEscape = { [weak self] in
            Task { @MainActor in self?.discardHandsFree() }
        }
        // The recorded combo breaks its tap sequence on the same events the
        // hold does (review 2026-10-11): any other key, and a shortcut change.
        holdMonitor.onKeyDown = { [weak self] keyCode, modifiers in
            self?.comboKeyDown(keyCode: keyCode, modifiers: modifiers)
        }
        NotificationCenter.default.addObserver(
            forName: PushToTalkTrigger.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptComboGesture() }
        }
    }

    /// The second tap was released: keep listening. Only a live capture can
    /// lock — a refused start (onboarding, model missing) has nothing to keep.
    func lockHandsFree() {
        switch state {
        case .warming, .recording:
            handsFree = true
            log.info("hands-free locked")
        default:
            log.info("hands-free lock ignored; state=\(String(describing: self.state))")
        }
    }

    /// Esc during a locked session: nothing is written, and the pill says so.
    func discardHandsFree() {
        guard isHandsFreeLive else { return }
        log.info("hands-free discarded")
        cancelDictation()
        state = .notice("Discarded")
    }

    /// Clears the session's flags whenever the state leaves live capture —
    /// every exit (finish, Esc, limit, lost mic, error) passes through here.
    func endHandsFreeIfCaptureEnded() {
        guard !isCaptureLive else { return }
        handsFree = false
        recordingLimitNear = false
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
    }

    /// Warn before the limit, then finish there. Generation-checked: the
    /// press is captured before the first await, so a timer that outlives its
    /// press can never finish the next one. Liveness is `isCaptureLive`, not
    /// `.recording`: a press caught mid-retry at either boundary is still the
    /// same press, and skipping it left the capture running past the limit.
    /// At the limit a warming press takes the release path, as a tap would.
    func armRecordingLimit(generation: Int) {
        recordingLimitTask?.cancel()
        let (warnAfter, finishAfter) = recordingLimitSchedule
        recordingLimitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(warnAfter * 1_000_000_000))
            guard let self, !Task.isCancelled, generation == self.pressGeneration,
                  self.isCaptureLive else { return }
            self.recordingLimitNear = true
            try? await Task.sleep(nanoseconds: UInt64((finishAfter - warnAfter) * 1_000_000_000))
            guard !Task.isCancelled, generation == self.pressGeneration, self.isCaptureLive else { return }
            log.info("recording limit reached — finishing")
            await self.stopAndProcess()
        }
    }

    // MARK: - Recorded combo

    /// The custom-shortcut path speaks the same gesture as the hold: a tap is
    /// never a dictation, a quick second tap locks, a tap while locked
    /// finishes. Capture starts at the press, as it always has here.
    func shortcutPressed() {
        let time = ProcessInfo.processInfo.systemUptime
        if isHandsFreeLive {
            shortcutPress = ShortcutPress(at: time, isSecondTap: false, finishes: true)
            return
        }
        let second = shortcutTaps.pressIsSecondTap(at: time)
        shortcutPress = ShortcutPress(at: time, isSecondTap: second, finishes: false)
        Task { @MainActor [weak self] in await self?.start() }
    }

    func shortcutReleased() {
        guard let press = shortcutPress else { return }
        shortcutPress = nil
        if press.finishes {
            // An interrupted finish press was a chord, as on the hold: the
            // session keeps listening.
            guard !press.interrupted else { return }
            Task { @MainActor [weak self] in await self?.stopAndProcess() }
            return
        }
        let time = ProcessInfo.processInfo.systemUptime
        let tap = DoubleTapDetector.isTap(pressedAt: press.at, releasedAt: time)
        // An interrupted press is no part of a gesture: it neither opens a
        // window nor locks. Its release still ends its capture — a tap is
        // discarded, a hold transcribes — or the mic would stay live.
        if press.interrupted {
            shortcutTaps.reset()
        } else {
            shortcutTaps.released(pressedAt: press.at, releasedAt: time, wasSecondTap: press.isSecondTap)
        }
        let lock = tap && press.isSecondTap && !press.interrupted
        Task { @MainActor [weak self] in
            guard let self else { return }
            if lock {
                self.lockHandsFree()
            } else if tap {
                self.cancelDictation()
            } else {
                await self.stopAndProcess()
            }
        }
    }

    /// A key that is not the combo itself breaks the combo's gesture.
    func comboKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        if let combo = KeyboardShortcuts.getShortcut(for: .toggleDictation),
           Int(keyCode) == combo.carbonKeyCode,
           modifiers == combo.modifiers.intersection(ModifierHoldMonitor.relevant) {
            return
        }
        interruptComboGesture()
    }

    /// Typing or a shortcut change breaks the gesture in BOTH places it
    /// lives: the tap history and the press still held (review 2026-10-11,
    /// second round) — clearing only the history let the held press's
    /// release reopen the window or complete a lock.
    func interruptComboGesture() {
        shortcutTaps.reset()
        shortcutPress?.interrupted = true
    }

    struct ShortcutPress {
        let at: TimeInterval
        let isSecondTap: Bool
        let finishes: Bool
        var interrupted = false
    }
}
