import Foundation

/// The hands-free gesture (P17, DECIDED 2026-10-11): two short taps of the
/// push-to-talk shortcut lock the mic. Pure timing over caller-supplied
/// timestamps, so the bare-modifier hold (`ModifierHoldMonitor`) and the
/// recorded combo (`Coordinator+HandsFree`) judge a tap identically and the
/// rules are unit-testable without events or a clock.
struct DoubleTapDetector {
    /// A press released within this is a tap, not a hold.
    static let tapMax: TimeInterval = 0.25
    /// The second tap must begin within this of the first tap's release.
    static let gapMax: TimeInterval = 0.40

    private var lastTapEndedAt: TimeInterval?

    /// A press begins at `time`: is it the second tap of a double-tap? Read
    /// at the press, because the mic goes live on the second tap.
    func pressIsSecondTap(at time: TimeInterval) -> Bool {
        guard let lastTapEndedAt else { return false }
        return time - lastTapEndedAt <= Self.gapMax
    }

    /// Whether a press held from `pressedAt` to `releasedAt` was a tap.
    static func isTap(pressedAt: TimeInterval, releasedAt: TimeInterval) -> Bool {
        releasedAt - pressedAt <= tapMax
    }

    /// Record a release. A tap can open a double-tap; anything longer, or
    /// the second tap itself, closes the window so a third tap starts over.
    mutating func released(pressedAt: TimeInterval, releasedAt: TimeInterval, wasSecondTap: Bool) {
        let tap = Self.isTap(pressedAt: pressedAt, releasedAt: releasedAt)
        lastTapEndedAt = tap && !wasSecondTap ? releasedAt : nil
    }

    /// Any other key, a chord, or a retarget breaks the sequence.
    mutating func reset() {
        lastTapEndedAt = nil
    }
}
