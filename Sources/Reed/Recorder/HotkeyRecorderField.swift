import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

extension Notification.Name {
    /// Posted by a `HotkeyRecorderField` when it arms/disarms (`object` is
    /// the new `Bool` armed state). `Coordinator` listens so it can stand the
    /// global push-to-talk hold monitor down while a shortcut is being
    /// recorded — without this, holding the trigger modifiers (e.g. ⌃⌥)
    /// mid-recording is indistinguishable from actually starting dictation,
    /// so real dictation kicks in and then swallows/cancels the very
    /// keypress the field is trying to capture.
    static let hotkeyRecorderArmedDidChange = Notification.Name("HotkeyRecorderField.armedDidChange")
}

/// The one push-to-talk recorder — click to arm, then press either a bare
/// modifier *hold* (⌃⌥, released with no other key) or a full combo (⌃⌥R).
/// One field, both directions, no preset menu: holds can't be typed into
/// `KeyboardShortcuts.Recorder`, which is why this exists.
///
/// Shared by onboarding's HotkeyStep and Settings → Dictation so the two can
/// never disagree about how a hotkey is captured or stored. Storage is always
/// `PushToTalkTrigger`: a hold applies the matching hold case (which clears any
/// recorded shortcut), a combo stores the shortcut and applies `.custom`.
struct HotkeyRecorderField: View {
    /// Onboarding renders a wide field under a label; Settings renders it on
    /// the trailing edge of a card row, where it hugs its keycaps.
    enum Layout { case wide, row }

    var layout: Layout = .wide
    /// The recorded combo, or nil when a bare-modifier hold is in effect.
    /// Bound so the host can react (onboarding offers "Use ⌃⌥ instead").
    @Binding var custom: KeyboardShortcuts.Shortcut?
    /// Fires when the field arms/disarms, so a host can hide competing
    /// controls while the next keypress is being captured.
    var onArmedChange: (Bool) -> Void = { _ in }

    /// Re-renders the keycaps when the hold changes — including changes made
    /// from the other surface while both are open.
    @AppStorage(PushToTalkTrigger.defaultsKey) private var triggerRaw = PushToTalkTrigger.controlOption.rawValue
    /// Tracks whether the hosting window is key. The arm monitors are LOCAL
    /// (`addLocalMonitorForEvents`) and receive nothing while Reed isn't the
    /// key window — so an armed field whose window loses focus could never
    /// see another event, stayed `recording` forever, and kept the global
    /// push-to-talk hold stood down for the rest of the session with no
    /// visible cause (review 2026-08-26). `.onDisappear` doesn't cover it:
    /// the Settings window is ordered out, not torn down. Losing key status
    /// disarms instead — the user re-clicks to record.
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var recording = false
    @State private var hovering = false
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var heldFlags: NSEvent.ModifierFlags = []

    var body: some View {
        Button {
            recording ? disarm() : arm()
        } label: {
            HStack(spacing: 5) {
                if recording {
                    Text(prompt)
                        .font(ReedFont.ui(13))
                        .foregroundStyle(Onb.slate)
                        .lineLimit(1)
                } else {
                    ForEach(Array(keycapParts.enumerated()), id: \.offset) { _, part in
                        KeycapView(symbol: part)
                    }
                }
                if layout == .wide { Spacer(minLength: 0) }
            }
            .padding(.horizontal, layout == .wide ? 12 : SettingsSpace.sm)
            .padding(.vertical, layout == .wide ? 8 : SettingsSpace.xs)
            .frame(minHeight: layout == .wide ? 40 : 0)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Onb.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            // E1 focus glow — recording is the "armed input" state.
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(recording ? Onb.green.opacity(0.18) : .clear)
                    .padding(-3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.fullRuleHelp)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { disarm() }
        // See controlActiveState above: focus left the window → disarm.
        .onChange(of: controlActiveState) { _, state in
            if state != .key { disarm() }
        }
        // Catch changes made behind our back (onboarding and Settings open
        // side by side, or the hold reset button).
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            let now = KeyboardShortcuts.getShortcut(for: .toggleDictation)
            if now != custom { custom = now }
        }
    }

    private var prompt: String {
        layout == .wide ? "Type a combo, or ⌃⌥ alone for the default" : "Press keys…"
    }

    /// The one authoritative explanation of what's allowed, in full — too
    /// long for the field itself, so it lives as a hover tooltip (both
    /// layouts) and, in onboarding, as standing text underneath (HotkeyStep).
    /// The rule the UI promises ("⌃, ⌥, or ⌘ plus a key"), enforced: a
    /// shift-only combo collides with ordinary typing and was silently
    /// accepted before (finding 2026-08-25).
    static func hasRequiredModifier(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.isDisjoint(with: [.control, .option, .command])
    }

    /// The custom recorder writes via `setShortcut` directly, skipping the
    /// bundled recorder's validation (review 2026-08-25) — so refuse combos
    /// the SYSTEM already owns (⌘Space etc.): they'd save but never fire, or
    /// fight the system action. Mirrors the library's internal
    /// `isTakenBySystem` via the same Carbon symbolic-hot-keys table.
    static func isSystemReserved(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        var hotKeysRef: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&hotKeysRef) == noErr,
              let hotKeys = hotKeysRef?.takeRetainedValue() as? [[String: Any]] else { return false }
        return hotKeys.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let keyCode = entry[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int else { return false }
            return keyCode == shortcut.carbonKeyCode && modifiers == shortcut.carbonModifiers
        }
    }

    static let fullRuleHelp =
        "A combo needs ⌃, ⌥, or ⌘ plus a key (e.g. ⌃⌥R). "
        + "Or press ⌃⌥, ⌃⌘, or ⌥⌘."

    private var borderColor: Color {
        if recording { return Onb.green }
        if hovering { return Onb.slate }
        return Onb.hair
    }

    /// Current value as per-key glyphs: the recorded combo, or the hold
    /// default.
    private var keycapParts: [String] {
        if let custom { return custom.description.map(String.init) }
        let trigger = PushToTalkTrigger(rawValue: triggerRaw) ?? .controlOption
        guard trigger.isHold else { return PushToTalkTrigger.controlOption.keycap.map(String.init) }
        return trigger.keycap.map(String.init)
    }

    // MARK: - Recording

    /// Arm local monitors: the next combo becomes the hotkey, and a bare
    /// modifier pair (pressed and released with no key) switches back to the
    /// matching hold — the recorder must accept both directions, not just
    /// hold→combo. Esc cancels and keeps whatever was set. Events are consumed
    /// while armed so Esc doesn't also trigger the footer's Back and letters
    /// don't beep.
    private func arm() {
        recording = true
        onArmedChange(true)
        NotificationCenter.default.post(name: .hotkeyRecorderArmedDidChange, object: true)
        heldFlags = []
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                disarm()
                return nil
            }
            heldFlags = []
            guard let shortcut = KeyboardShortcuts.Shortcut(event: event),
                  Self.hasRequiredModifier(shortcut.modifiers),
                  !Self.isSystemReserved(shortcut) else { return nil }
            KeyboardShortcuts.setShortcut(shortcut, for: .toggleDictation)
            PushToTalkTrigger.custom.apply()
            custom = shortcut
            disarm()
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let now = event.modifierFlags.intersection([.control, .option, .command, .shift])
            if now.isEmpty {
                // Full release: a bare-modifier gesture completed — map it to
                // a hold if it matches one, otherwise stay armed.
                if let hold = PushToTalkTrigger.hold(matching: heldFlags) {
                    hold.apply()
                    custom = nil
                    disarm()
                }
                heldFlags = []
            } else {
                heldFlags.formUnion(now)
            }
            return event
        }
    }

    private func disarm() {
        if recording {
            onArmedChange(false)
            NotificationCenter.default.post(name: .hotkeyRecorderArmedDidChange, object: false)
        }
        recording = false
        heldFlags = []
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }
}
