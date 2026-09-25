import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // No built-in default: push-to-talk defaults to a bare ⌃⌥ *hold*, handled by
    // ModifierHoldMonitor (the KeyboardShortcuts library can only bind
    // key+modifier combos, not a lone modifier). A nil shortcut here means "use
    // the ⌃⌥-hold default"; recording a combo in Settings/onboarding overrides
    // it. Users who set a custom combo keep it; anyone on the old ⌃⌥D default
    // moves to the ⌃⌥ hold.
    static let toggleDictation = Self("toggleDictation")
}
