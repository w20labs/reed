import CoreAudio
import Foundation

private let mlog = Log(category: "audio")

/// The two HAL properties that make holding the mic open acceptable.
///
/// Reed keeps the input stream running between dictations so a Bluetooth link
/// stays in the call profile and the next press is ~132 ms instead of ~1855 ms
/// (design: "Bluetooth · holding the link warm"). That is only defensible
/// because of these two:
///
/// - `kAudioHardwarePropertyProcessInputMute` is a guarantee the system
///   enforces — "all data coming into the process for all devices will be
///   silent". Because macOS enforces it, macOS does not raise the orange
///   microphone indicator for it. This is the difference between discarding
///   audio ourselves, which would deserve an indicator, and never receiving
///   it, which does not. Verified on macOS 26.5.2.
/// - `kAudioHardwarePropertySleepingIsAllowed` puts back what holding an audio
///   stream takes away: I/O normally blocks idle sleep, so without this Reed
///   would quietly keep the Mac awake — a far worse cost than the one being
///   saved.
enum ProcessAudio {
    /// Silences every input this process receives, at the HAL. Returns whether
    /// it took: callers must treat failure as "we are audible now", never
    /// assume success, or Reed would hold a live mic believing it was muted.
    @discardableResult
    static func setInputMuted(_ muted: Bool) -> Bool {
        guard setUInt32(kAudioHardwarePropertyProcessInputMute, muted ? 1 : 0) else {
            mlog.error("ProcessInputMute(\(muted)) FAILED — treating input as live")
            return false
        }
        // Read back rather than trusting the write: this decides whether the
        // user is being recorded without an indicator, so it is worth the
        // second call.
        guard let value = getUInt32(kAudioHardwarePropertyProcessInputMute),
              (value != 0) == muted else {
            mlog.error("ProcessInputMute(\(muted)) did not stick on readback")
            return false
        }
        return true
    }

    /// True when the process is currently input-muted at the HAL.
    static var isInputMuted: Bool {
        (getUInt32(kAudioHardwarePropertyProcessInputMute) ?? 0) != 0
    }

    /// Lets the CPU idle-sleep even though this process is running audio I/O.
    /// Set once, when Reed first starts holding a stream open.
    static func allowIdleSleep() {
        if setUInt32(kAudioHardwarePropertySleepingIsAllowed, 1) {
            mlog.info("idle sleep re-allowed while holding the input stream")
        } else {
            mlog.error("could not re-allow idle sleep — not holding the mic open")
        }
    }

    // MARK: - Private

    private static func setUInt32(_ selector: AudioObjectPropertySelector, _ value: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutable = value
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &mutable)
        return status == noErr
    }

    private static func getUInt32(_ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}
