import Foundation

/// When the proactive "this Bluetooth mic will slow you down" toast is allowed
/// to fire.
///
/// Frequency is the whole design here. Firing on every dictation trains the
/// user to dismiss it unread; firing once ever is missed by anyone who
/// happened to be away from the keyboard. So: at most once an hour, and
/// "Don't show again" is permanent — someone who only owns AirPods has heard
/// us and should not be nagged for the life of the app.
///
/// A struct over injectable `UserDefaults` rather than static functions, so
/// the window and the suppression flag can be tested without touching the
/// user's real defaults or waiting an hour.
struct BluetoothNudgePolicy {
    static let interval: TimeInterval = 3600

    private static let suppressedKey = "bluetoothNudgeSuppressed"
    private static let lastShownKey = "bluetoothNudgeLastShownAt"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shouldShow(now: Date = Date()) -> Bool {
        guard !defaults.bool(forKey: Self.suppressedKey) else { return false }
        guard let last = defaults.object(forKey: Self.lastShownKey) as? Date else { return true }
        // A clock that moved backwards (timezone change, NTP correction)
        // would otherwise lock the nudge out until wall time caught up.
        guard now >= last else { return true }
        return now.timeIntervalSince(last) >= Self.interval
    }

    func recordShown(now: Date = Date()) {
        defaults.set(now, forKey: Self.lastShownKey)
    }

    func suppressForever() {
        defaults.set(true, forKey: Self.suppressedKey)
    }
}
