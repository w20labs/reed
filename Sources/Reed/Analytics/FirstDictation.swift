import Foundation

/// The two facts about a user's FIRST dictation that decide whether Reed felt
/// like magic: which transport the mic was on, and how long until it could
/// actually hear (design: "Telemetry" + decision-tree Question 3).
///
/// Recorded locally the moment the first dictation confirms real signal.
/// Transmission is deferred: the facts sit in UserDefaults and are emitted
/// exactly once, only if the user ever turns analytics on in Settings →
/// Privacy. Never turned on → they never leave the Mac. The sample is
/// therefore "users who opted in", which is named rather than hidden.
enum FirstDictation {
    static let transportKey = "firstDictationTransport"
    static let ttaKey = "firstDictationTimeToAudioMs"
    static let emittedKey = "firstDictationEmitted"

    /// Store the facts if this is the first confirmed dictation. Content-free
    /// by construction: a transport enum and a millisecond count.
    static func recordIfFirst(transport: String, timeToAudioMs: Int,
                              defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: transportKey) == nil else { return }
        defaults.set(transport, forKey: transportKey)
        defaults.set(timeToAudioMs, forKey: ttaKey)
    }

    /// Emit once, if recorded and analytics is on and not already emitted.
    /// Called at launch, so the event follows the first launch after the user
    /// turns analytics on.
    static func emitIfDue(analyticsEnabled: Bool = Analytics.isEnabled,
                          defaults: UserDefaults = .standard,
                          send: (String, String) -> Void = Analytics.firstDictation) {
        guard analyticsEnabled,
              !defaults.bool(forKey: emittedKey),
              let transport = defaults.string(forKey: transportKey) else { return }
        send(transport, ttaBucket(defaults.integer(forKey: ttaKey)))
        defaults.set(true, forKey: emittedKey)
    }

    /// Buckets, not milliseconds — a raw latency could fingerprint a machine.
    static func ttaBucket(_ ms: Int) -> String {
        switch ms {
        case ..<200: return "<200ms"
        case ..<500: return "200-500ms"
        case ..<1000: return "500ms-1s"
        case ..<2000: return "1-2s"
        default: return ">=2s"
        }
    }
}
