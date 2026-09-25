import AppKit

/// Deep link to System Settings ▸ Sound, where the Mac's input device is
/// chosen.
///
/// Reed can't make that choice itself: a Bluetooth mic only becomes usable
/// once macOS makes it the *system* input (see `AudioInputDevice.pinnableDevices`),
/// and no per-app API can trigger that. So every surface that explains the
/// limitation hands the user this instead of an apology.
enum SoundSettings {
    /// Ventura and later serve the pane from an extension bundle id. The
    /// pre-Ventura URL is kept as a fallback so the button still lands
    /// somewhere useful if the modern one ever stops resolving, rather than
    /// appearing to do nothing.
    static func open() {
        // The bare URL lands on whichever tab (usually Output) was last open;
        // the "input" anchor — the same one AppleScript's
        // `reveal anchor "input" of pane id "com.apple.preference.sound"` used
        // — is what actually puts the mic picker in front of the user.
        let modern = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!
        if NSWorkspace.shared.open(modern) { return }
        let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!
        NSWorkspace.shared.open(legacy)
    }
}
