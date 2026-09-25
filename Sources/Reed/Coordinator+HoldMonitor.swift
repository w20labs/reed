import AppKit

/// Push-to-talk hold-monitor wiring: split out of Coordinator.swift to keep
/// it under the swiftlint file-length cap (see Coordinator+ModeHotkeys.swift
/// for the same pattern).
extension Coordinator {
    /// Wire the modifier-hold trigger to the pipeline. The monitor only fires
    /// while a hold is selected (custom-shortcut mode retargets it to nil), so
    /// the hold and KeyboardShortcuts paths never overlap.
    func configureHoldMonitor() {
        holdMonitor.onStart = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.start() }
        }
        holdMonitor.onStop = { [weak self] chorded in
            guard let self else { return }
            if chorded {
                self.cancelDictation()  // a shortcut, not dictation — discard
            } else {
                Task { @MainActor in await self.stopAndProcess() }
            }
        }
        holdMonitor.start()
        // Retarget the hold when the user changes the trigger in Settings.
        // NOT while a HotkeyRecorderField is capturing (review 2026-08-26):
        // onboarding's "Use ⌃⌥ instead" posts didChange, and re-arming here
        // while the Settings field was still armed defeated the stand-down —
        // holding the trigger to record a combo started a real dictation.
        // The armed-count observer below restores the (new) trigger when the
        // last field disarms; it reads PushToTalkTrigger.current at that
        // moment, so the change is never lost.
        NotificationCenter.default.addObserver(
            forName: PushToTalkTrigger.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, activeHotkeyRecordings == 0 else { return }
            self.holdMonitor.setTrigger(PushToTalkTrigger.current.modifiers)
        }
        // Stand the hold down while any HotkeyRecorderField is capturing a
        // shortcut — otherwise holding the live trigger (e.g. ⌃⌥) to record
        // a combo starts real dictation instead, which then reads the
        // following keypress as "that's a shortcut" and cancels itself
        // before the field ever sees a clean capture.
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecorderArmedDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let armed = note.object as? Bool else { return }
            activeHotkeyRecordings = max(0, activeHotkeyRecordings + (armed ? 1 : -1))
            holdMonitor.setTrigger(activeHotkeyRecordings > 0 ? nil : PushToTalkTrigger.current.modifiers)
        }
    }
}
