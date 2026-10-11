import AppKit

/// Push-to-talk via a *bare modifier hold* (e.g. ⌃⌥) — something the
/// KeyboardShortcuts library can't express, since it only records key+modifier
/// combos. Watches `.flagsChanged` (globally + locally) for the moment the
/// trigger modifiers are held *alone* and fires `onStart`; fires `onStop` when
/// they're released.
///
/// A non-modifier keypress during the hold means the user is typing a real
/// shortcut (⌃⌥→, VoiceOver's ⌃⌥, an app combo), so we abort with
/// `chorded: true` and let the caller discard the take. A short arm delay keeps
/// a fast chord (⌃⌥C) from ever spinning up the audio engine: `onStart` only
/// fires once the trigger has been held alone past the delay, so a quick
/// shortcut cancels before capture begins.
///
/// Hands-free (P17): two taps lock the mic. A press shorter than
/// `DoubleTapDetector.tapMax` is a tap, never a dictation — its take is
/// discarded silently. A second tap starts capture at the press, like a hold,
/// and its quick release fires `onLock` instead of `onStop` (or
/// `onStartLocked` when released inside the arm delay). While the
/// coordinator reports a locked session (`isLocked`), keys are free, a clean
/// tap of the trigger fires `onFinish`, and Esc fires `onEscape`.
@MainActor
final class ModifierHoldMonitor {
    /// Fired when the trigger modifiers have been held alone past the arm delay.
    var onStart: (() -> Void)?
    /// Fired when the hold ends. `chorded` = a non-modifier key joined the hold
    /// (a real shortcut), so the caller should discard rather than transcribe.
    var onStop: ((_ chorded: Bool) -> Void)?
    /// The second tap of a double-tap was released: keep listening hands-free.
    var onLock: (() -> Void)?
    /// The second tap was released before capture began: start AND lock in
    /// one call, so the lock never depends on two calls landing in order.
    var onStartLocked: (() -> Void)?
    /// A clean tap of the trigger during a locked session: finish and write.
    var onFinish: (() -> Void)?
    /// Esc during a locked session: discard.
    var onEscape: (() -> Void)?
    /// Whether a hands-free session is live. The coordinator is the
    /// authority: a session that ended any other way (the five-minute limit,
    /// a lost mic, an error) reads false here at the next event, so no stale
    /// lock can survive in the monitor.
    var isLocked: () -> Bool = { false }

    /// The modifier set to match, or nil to stand down (custom-shortcut mode).
    private var trigger: NSEvent.ModifierFlags?
    /// The trigger currently armed for matching — nil means stood down (no
    /// hold will fire). Read-only outside; set via `setTrigger`.
    var currentTrigger: NSEvent.ModifierFlags? { trigger }
    private let armDelay: TimeInterval
    /// The modifier bits that make up "the whole set" — caps lock is excluded so
    /// a stray caps-lock state never blocks the trigger match.
    private static let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// `finishing`: the trigger is down during a locked session; a clean
    /// release finishes it, a chord does not.
    private enum Phase { case idle, armed, active, finishing }
    private var phase: Phase = .idle
    /// Set when a chord aborts mid-hold; blocks re-arming until the trigger is
    /// fully released, so the rest of a shortcut sequence can't restart capture.
    private var blocked = false
    private var armWork: DispatchWorkItem?
    private var taps = DoubleTapDetector()
    /// When the current press reached the bare trigger set.
    private var pressedAt: TimeInterval = 0
    /// Whether the current press is the second tap of a double-tap.
    private var pressIsSecondTap = false
    /// Uptime clock, injectable so tests drive tap timing exactly.
    private let now: () -> TimeInterval
    static let escapeKeyCode: UInt16 = 53

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private let mlog = Log(category: "modhold")

    init(trigger: NSEvent.ModifierFlags?, armDelay: TimeInterval = 0.12,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.trigger = trigger?.intersection(Self.relevant)
        self.armDelay = armDelay
        self.now = now
    }

    /// Retarget the hold live (the user changed the trigger in Settings). Passing
    /// nil stands the monitor down for custom-shortcut mode. Resets any in-flight
    /// arm/hold so a stale phase can't leak across the change.
    ///
    /// A LIVE hold must be ended, not abandoned (review 2026-08-26): resetting
    /// phase silently meant onStop never fired, so neither stopAndProcess nor
    /// cancelDictation ran — the mic stayed live with the HUD stuck on
    /// Listening, and the eventual release was swallowed by the stood-down
    /// guard. Fired as `chorded: true`: retargeting mid-hold is a UI action
    /// (clicking a HotkeyRecorderField, picking a new trigger), not a release
    /// meant to commit dictation — the caller discards the take and stops the
    /// mic, exactly like a chord abort.
    func setTrigger(_ newValue: NSEvent.ModifierFlags?) {
        cancelArm()
        let abandonedLiveHold = phase == .active
        phase = .idle
        blocked = false
        taps.reset()
        trigger = newValue?.intersection(Self.relevant)
        if abandonedLiveHold { onStop?(true) }
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        // Local monitor covers the case where Reed itself is key (Settings open);
        // it must return the event so normal typing/shortcuts still pass through.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        mlog.info("modifier-hold monitor started")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        cancelArm()
        // Same abandonment hole as setTrigger: tearing the monitor down
        // mid-hold must end the dictation, or the mic outlives the monitor.
        let abandonedLiveHold = phase == .active
        phase = .idle
        if abandonedLiveHold { onStop?(true) }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged: flagsChanged(event.modifierFlags.intersection(Self.relevant))
        case .keyDown: keyDown(keyCode: event.keyCode)
        default: break
        }
    }

    func flagsChanged(_ active: NSEvent.ModifierFlags) {
        guard let trigger else { return }  // custom-shortcut mode → no hold
        if active == trigger {
            guard !blocked, phase == .idle else { return }
            if isLocked() {
                // Hands-free: the trigger finishes on a clean release; no
                // capture starts, nothing arms.
                phase = .finishing
                return
            }
            pressedAt = now()
            pressIsSecondTap = taps.pressIsSecondTap(at: pressedAt)
            phase = .armed
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .armed else { return }
                self.phase = .active
                self.onStart?()
            }
            armWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + armDelay, execute: work)
        } else {
            // Any change away from the exact trigger set = release (or an
            // extra modifier joined). The chord block latches only when we're
            // LEAVING a hold that was already engaged with keys still down —
            // an extra modifier joined, then dropped, must not start a second
            // recording when the trigger set reappears (finding 2026-08-25).
            //
            // Latching from `.idle` too would kill the hold outright: a ⌃⌥
            // hold arrives as two events, and the intermediate ⌃-alone step
            // is itself "away from the trigger with a key still held", so it
            // blocked the very trigger event that followed it. The block
            // always clears on a full release.
            //
            // A release LIFTS trigger keys (a subset remains); anything else
            // is an extra modifier joining — a chord, which breaks a tap.
            let released = active.isSubset(of: trigger)
            switch phase {
            case .armed:
                cancelArm(); phase = .idle; blocked = !active.isEmpty
                if released { releasedBeforeCapture() } else { taps.reset() }
            case .active:
                phase = .idle; blocked = !active.isEmpty
                if released { releasedDuringCapture() } else { taps.reset(); onStop?(false) }
            case .finishing:
                phase = .idle; blocked = !active.isEmpty
                if released { onFinish?() }
            case .idle: if active.isEmpty { blocked = false }
            }
        }
    }

    /// Released inside the arm delay: no capture began. A first tap only
    /// opens the double-tap window; a quick second tap starts capture
    /// already locked.
    private func releasedBeforeCapture() {
        let releasedAt = now()
        let lock = pressIsSecondTap && DoubleTapDetector.isTap(pressedAt: pressedAt, releasedAt: releasedAt)
        taps.released(pressedAt: pressedAt, releasedAt: releasedAt, wasSecondTap: pressIsSecondTap)
        if lock { onStartLocked?() }
    }

    /// Released after capture began: a quick second tap locks; any other tap
    /// is discarded silently (a tap is never a dictation); a hold transcribes.
    private func releasedDuringCapture() {
        let releasedAt = now()
        let tap = DoubleTapDetector.isTap(pressedAt: pressedAt, releasedAt: releasedAt)
        taps.released(pressedAt: pressedAt, releasedAt: releasedAt, wasSecondTap: pressIsSecondTap)
        if tap && pressIsSecondTap {
            onLock?()
        } else {
            onStop?(tap)
        }
    }

    func keyDown(keyCode: UInt16 = 0) {
        if isLocked() {
            // Hands-free: the keyboard is free. Esc discards; a key while the
            // trigger is down was a shortcut (⌃⌥C), so that press finishes
            // nothing.
            if keyCode == Self.escapeKeyCode { phase = .idle; onEscape?(); return }
            if phase == .finishing { phase = .idle; blocked = true }
            return
        }
        // Any key breaks a double-tap sequence: typing between taps is not
        // a gesture.
        taps.reset()
        switch phase {
        case .armed:
            // A key joined before capture even began — it's a shortcut, not us.
            cancelArm(); phase = .idle; blocked = true
        case .active:
            phase = .idle; blocked = true; onStop?(true)
        case .idle, .finishing:
            break
        }
    }

    private func cancelArm() {
        armWork?.cancel()
        armWork = nil
    }
}
