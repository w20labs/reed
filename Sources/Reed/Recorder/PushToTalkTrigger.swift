import AppKit
import KeyboardShortcuts

/// How the user starts dictation. A *hold* is a bare modifier combo (⌃⌥, ⌃⌘,
/// ⌥⌘) handled by `ModifierHoldMonitor`; `.custom` hands off to a recorded
/// key+modifier shortcut (KeyboardShortcuts). `KeyboardShortcuts.Recorder`
/// can't capture a lone modifier, which is why `HotkeyRecorderField` watches
/// raw events and records both directions in one field.
///
/// Persisted as a raw string under `defaultsKey`. Changing it broadcasts
/// `didChange` so the Coordinator can retarget the monitor live.
enum PushToTalkTrigger: String, CaseIterable {
    case controlOption, controlCommand, optionCommand, custom

    static let defaultsKey = "pushToTalkTrigger"
    static let didChange = Notification.Name("reed.pushToTalkTriggerChanged")

    /// The modifier set to hold, or nil for `.custom` (no hold — uses the
    /// recorded shortcut instead).
    var modifiers: NSEvent.ModifierFlags? {
        switch self {
        case .controlOption: return [.control, .option]
        case .controlCommand: return [.control, .command]
        case .optionCommand: return [.option, .command]
        case .custom: return nil
        }
    }

    /// Compact keycap for the recorder field and menu (mono glyphs).
    var keycap: String {
        switch self {
        case .controlOption: return "⌃⌥"
        case .controlCommand: return "⌃⌘"
        case .optionCommand: return "⌥⌘"
        case .custom: return "⌘…"
        }
    }

    var isHold: Bool { self != .custom }

    /// The hold a released bare-modifier set maps to, if any — the recorder's
    /// combo→hold direction (`HotkeyRecorderField`). Pure and static so the
    /// mapping is unit-testable without AppKit event plumbing.
    static func hold(matching flags: NSEvent.ModifierFlags) -> PushToTalkTrigger? {
        allCases.first { $0.isHold && $0.modifiers == flags }
    }

    /// The persisted choice, defaulting to ⌃⌥.
    static var current: PushToTalkTrigger {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let value = PushToTalkTrigger(rawValue: raw) else { return .controlOption }
        return value
    }

    /// Persist this choice and broadcast so the Coordinator reconfigures. A hold
    /// also clears any recorded shortcut, so the hold and custom paths can never
    /// both fire.
    func apply() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        if isHold {
            KeyboardShortcuts.setShortcut(nil, for: .toggleDictation)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
