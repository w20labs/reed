import Foundation

/// The audio actions onboarding needs, passed in as closures so the steps
/// stay decoupled from Coordinator (they only ever see this façade).
struct OnboardingAudio {
    /// The device Reed would record from right now.
    var currentInput: () -> AudioInputDevice?
    /// The system-default input — the "no pin" option, listed even while a
    /// pin points elsewhere (hand-test finding: building the menu from the
    /// CURRENT device made the Bluetooth default vanish as soon as the user
    /// pinned away from it, taking the way back — and the footnote — with it).
    var systemDefault: () -> AudioInputDevice?
    /// Built-in and wired devices — never Bluetooth (pinnableDevices()).
    var pinnable: () -> [AudioInputDevice]
    /// Pin a device by UID; nil clears the pin (back to the system default).
    var pin: (String?) -> Void
    /// Silent pre-warm for the try-it box (AudioRecorder.beginWarmHold).
    var prewarmHold: () -> Void
}
