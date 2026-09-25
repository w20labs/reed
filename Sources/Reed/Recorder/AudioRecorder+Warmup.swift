import Foundation

/// Warm-up instrumentation helpers, split from AudioRecorder.swift for the
/// file-length cap. The stored timestamps live on the class itself; these are
/// the two operations performed on them.
extension AudioRecorder {
    /// Called from the tap on the first frame of a recording. Two assignments,
    /// no allocation and no device enumeration — this runs on the audio thread.
    func noteFirstFrame(sampleRate: Double) {
        warmFirstFrameAt = Date()
        warmSampleRate = sampleRate
    }

    /// Milliseconds from the hotkey going down to `moment`, or nil if either
    /// end is missing (e.g. the user released before real signal arrived).
    func warmMillis(to moment: Date?) -> Int? {
        guard let warmPressedAt, let moment else { return nil }
        return Int(moment.timeIntervalSince(warmPressedAt) * 1000)
    }
}
