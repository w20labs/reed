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
@MainActor
final class ModifierHoldMonitor {
    /// Fired when the trigger modifiers have been held alone past the arm delay.
    var onStart: (() -> Void)?
    /// Fired when the hold ends. `chorded` = a non-modifier key joined the hold
    /// (a real shortcut), so the caller should discard rather than transcribe.
    var onStop: ((_ chorded: Bool) -> Void)?

    /// The modifier set to match, or nil to stand down (custom-shortcut mode).
    private var trigger: NSEvent.ModifierFlags?
    /// The trigger currently armed for matching — nil means stood down (no
    /// hold will fire). Read-only outside; set via `setTrigger`.
    var currentTrigger: NSEvent.ModifierFlags? { trigger }
    private let armDelay: TimeInterval
    /// The modifier bits that make up "the whole set" — caps lock is excluded so
    /// a stray caps-lock state never blocks the trigger match.
    private static let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    private enum Phase { case idle, armed, active }
    private var phase: Phase = .idle
    /// Set when a chord aborts mid-hold; blocks re-arming until the trigger is
    /// fully released, so the rest of a shortcut sequence can't restart capture.
    private var blocked = false
    private var armWork: DispatchWorkItem?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private let mlog = Log(category: "modhold")

    init(trigger: NSEvent.ModifierFlags?, armDelay: TimeInterval = 0.12) {
        self.trigger = trigger?.intersection(Self.relevant)
        self.armDelay = armDelay
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
        case .keyDown: keyDown()
        default: break
        }
    }

    func flagsChanged(_ active: NSEvent.ModifierFlags) {
        guard let trigger else { return }  // custom-shortcut mode → no hold
        if active == trigger {
            guard !blocked, phase == .idle else { return }
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
            switch phase {
            case .armed: cancelArm(); phase = .idle; blocked = !active.isEmpty
            case .active: phase = .idle; onStop?(false); blocked = !active.isEmpty
            case .idle: if active.isEmpty { blocked = false }
            }
        }
    }

    func keyDown() {
        switch phase {
        case .armed:
            // A key joined before capture even began — it's a shortcut, not us.
            cancelArm(); phase = .idle; blocked = true
        case .active:
            phase = .idle; blocked = true; onStop?(true)
        case .idle:
            break
        }
    }

    private func cancelArm() {
        armWork?.cancel()
        armWork = nil
    }
}
