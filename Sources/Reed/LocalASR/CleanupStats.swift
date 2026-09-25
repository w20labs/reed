import Foundation

/// Instrumentation for the on-device cleanup model (2026-08-29): three of
/// 214 field dictations stalled to the 8 s hard deadline and fell back to
/// rules, and nothing recorded why. This actor keeps the recent call
/// durations (for an adaptive deadline) and counts timeouts. A call's
/// failure class travels in its reply (`LocalCleanup.ModelReply`), never
/// through a shared slot here (review 2026-09-05, P2).
actor CleanupStats {
    static let shared = CleanupStats()

    /// Recent successful call durations, newest last.
    private(set) var durations: [Double] = []
    private(set) var calls = 0
    private(set) var timeouts = 0

    static let window = 20
    /// Below this many samples the fixed deadline applies — a cold or slow
    /// Mac must not be judged on its first two calls.
    static let minSamples = 5
    static let floorDeadline: TimeInterval = 2.5
    static let ceilingDeadline: TimeInterval = 8

    func record(duration: Double) {
        calls += 1
        durations.append(duration)
        if durations.count > Self.window { durations.removeFirst(durations.count - Self.window) }
    }

    func recordFailure(timedOut: Bool) {
        calls += 1
        if timedOut { timeouts += 1 }
    }

    /// How long to wait for one call: four times the recent median, between
    /// 2.5 s and 8 s. On this Mac (median ~0.6 s) a stalled call costs 2.5 s
    /// instead of 8; a slow Mac with a 2 s median keeps the full 8.
    var adaptiveDeadline: TimeInterval {
        Self.deadline(forDurations: durations)
    }

    nonisolated static func deadline(forDurations durations: [Double]) -> TimeInterval {
        guard durations.count >= minSamples else { return ceilingDeadline }
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        return min(max(4 * median, floorDeadline), ceilingDeadline)
    }

    func reset() {
        durations = []
        calls = 0
        timeouts = 0
    }
}
