import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

private let alog = Log(category: "audio")

/// The preferred-microphone pin: applying it to the input unit and reading
/// back what the unit is actually bound to. Split from AudioRecorder+Capture
/// for the swiftlint file-length cap; conceptually these are capture helpers.
extension AudioRecorder {
    /// The device ID the input unit is actually bound to right now — read
    /// back from the unit itself, not inferred. `nil` when there's no input
    /// unit or the query fails.
    var boundInputDeviceID: AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
            0, &deviceID, &size)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    /// Same lookup, formatted for logging. Logged per capture.
    var boundInputDescription: String {
        guard let deviceID = boundInputDeviceID else { return "unknown (no input unit)" }
        return "\(AudioInputDevice.name(forDeviceID: deviceID)) [id \(deviceID)]"
    }

    /// Whether a preferred-mic pin is set but the input unit is no longer
    /// bound to it. A held-warm engine can drift onto the process's
    /// default-device aggregate without a stop/start cycle and without an
    /// `AVAudioEngineConfigurationChange` — observed when the default
    /// OUTPUT device changes underneath the hold (e.g. AirPods
    /// disconnecting), which reconfigures the aggregate the input node
    /// rides on even though the pinned mic itself never changed (field log
    /// 2026-08-16: bound device read "MacBook Pro Microphone" on one
    /// dictation and "CADefaultDeviceAggregate-<pid>-N" on the next, engine
    /// never stopped in between). Resuming onto that aggregate leaves the
    /// hold exposed to coreaudiod tearing it down on its own schedule — the
    /// suspected cause of the mic-indicator getting stuck on. Checked before
    /// every resume so a drift is caught and rebuilt rather than resumed.
    var isPinnedInputDrifted: Bool {
        guard let uid = AudioInputDevice.loadPreferredUID(),
              let pinnedID = AudioInputDevice.deviceID(forUID: uid) else { return false }
        return boundInputDeviceID != pinnedID
    }

    /// Pins capture to the user's preferred microphone (Settings/menu bar
    /// picker), if they've chosen one. Absent/empty preference means "system
    /// default" — today's original, untouched behavior — so this only ever
    /// engages when the user explicitly opted in, unlike an automatic pin
    /// (which broke clamshell-mode setups by silently forcing the built-in
    /// mic for everyone). Must run after `engine.prepare()`, which is what
    /// instantiates the underlying audio unit this sets the device on.
    @discardableResult
    func pinPreferredInputIfSet() -> AudioDeviceID? {
        guard let uid = UserDefaults.standard.string(forKey: AudioInputDevice.preferredUIDDefaultsKey),
              !uid.isEmpty,
              let deviceID = AudioInputDevice.deviceID(forUID: uid) else { return nil }
        // Bluetooth can't be pinned — see AudioInputDevice.pinnableDevices().
        // The pickers no longer offer it, but a pin written by an older build,
        // or one set while the device was disconnected, still reaches this
        // line, and honouring it would produce a permanently silent recording.
        // Falling through to the system default is the only outcome here that
        // can actually capture audio.
        guard !AudioInputDevice.isBluetooth(deviceID) else {
            alog.info("ignoring Bluetooth pin '\(uid)' — can't be pinned; using system default")
            return nil
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            alog.error("no input audioUnit — can't pin to preferred mic")
            return nil
        }
        var mutableID = deviceID
        selfInflictedPinAt = Date()
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            alog.info("pinned input to preferred mic (device \(mutableID))")
            return deviceID
        } else {
            // Nothing changed, so no config-change notification is coming —
            // don't leave the stamp set to absorb a later, genuine one.
            selfInflictedPinAt = nil
            alog.error("failed to pin input to preferred mic: status \(status)")
        }
        return nil   // pin didn't take: the node keeps the system default
    }
}
