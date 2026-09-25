import CoreAudio
import Foundation

private let dlog = Log(category: "audio")

/// A selectable audio input device, surfaced in the menu bar and Settings
/// microphone pickers and used to classify the slow-Bluetooth-mic suggestion.
struct AudioInputDevice: Identifiable, Equatable {
    /// CoreAudio device UID — stable across reboots/reconnects, unlike
    /// AudioDeviceID (which is reassigned per connection). Preferences
    /// persist this, not the transient ID.
    let id: String
    let name: String
    let isBuiltIn: Bool
    let isBluetooth: Bool
    /// Continuity Capture (an iPhone acting as this Mac's mic). Pinnable and
    /// listed in pickers, but never RECOMMENDED as the instant-start remedy —
    /// a mic that can walk out of the room is bad advice.
    var isContinuity: Bool = false

    /// Content-free transport label for metrics ("builtin"/"wired"/"bluetooth").
    var transport: String {
        if isBuiltIn { return "builtin" }
        return isBluetooth ? "bluetooth" : "wired"
    }

    /// UserDefaults key for the user's chosen input device UID. Absent/empty
    /// means "system default" — today's original, untouched behavior.
    static let preferredUIDDefaultsKey = "preferredMicrophoneUID"

    /// Whether the user has pinned a specific input device.
    static var hasPreferredPin: Bool {
        !(UserDefaults.standard.string(forKey: preferredUIDDefaultsKey) ?? "").isEmpty
    }

    /// All currently connected devices that expose at least one input stream.
    ///
    /// Never logs the healthy inventory (2026-09-04): callers reach here at
    /// UI-tick rate — the Settings microphone row enumerates twice per body
    /// pass — and the summary line was 89% of reed.log on a fresh install,
    /// evicting real history from the 5 MB / 72 h file that rides support
    /// reports. Same class as the per-device line removed on 2026-08-26, one
    /// level up. Rejections are still logged by `device(forDeviceID:)`.
    static func availableDevices() -> [AudioInputDevice] {
        inputDeviceIDs().compactMap(device(forDeviceID:))
    }

    /// The devices Reed can actually pin to its own audio unit.
    ///
    /// Pinning sets `kAudioOutputUnitProperty_CurrentDevice`. A built-in or
    /// wired device always exposes a live input stream, so that works. A
    /// Bluetooth device only exposes one once macOS has switched it from A2DP
    /// to HFP — and ONLY the system input selection triggers that switch,
    /// never an app's per-unit choice. Pinning AirPods while they sit in A2DP
    /// hands the engine a device that returns no audio at all: measured as
    /// `wav=0` bytes, -120 dB, zero frames, indefinitely, with no error and no
    /// timeout. The occasional success only happened when something else had
    /// already put the device in HFP, which is exactly why it looked flaky
    /// rather than broken.
    ///
    /// So Bluetooth is excluded from every pick-a-mic surface: offering a
    /// choice that silently kills dictation is worse than not offering it.
    /// Those mics still work as the *system* input, which is where the UI
    /// steers people instead (`MenuNotice.bluetooth`, `BluetoothNudge`).
    static func pinnableDevices() -> [AudioInputDevice] {
        availableDevices().filter { !$0.isBluetooth }
    }

    /// Whether any Bluetooth input is connected right now. Drives whether the
    /// pickers bother explaining the omission — with none connected nothing
    /// is missing from the list, so the explanation would be noise.
    static func hasBluetoothInput() -> Bool {
        availableDevices().contains { $0.isBluetooth }
    }

    static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        device(forDeviceID: deviceID)?.isBluetooth ?? false
    }

    /// Reads the persisted pin, dropping it if it names a mic Reed cannot pin.
    ///
    /// Builds before 2026-07-28 let users pick AirPods here, which never
    /// actually worked. Left in place such a pin keeps producing silent dead
    /// dictations, and the picker that set it no longer lists Bluetooth, so
    /// there is no longer any UI to clear it with — the user would be stuck.
    /// Clearing it falls back to the system default, which does work.
    ///
    /// A UID that simply isn't in the list is left alone: that normally means
    /// "unplugged right now", and the pin should take effect again when the
    /// device returns. Only a device that is present *and* Bluetooth is
    /// known-unusable.
    static func loadPreferredUID(defaults: UserDefaults = .standard,
                                 connected: [AudioInputDevice]? = nil) -> String? {
        guard let uid = defaults.string(forKey: preferredUIDDefaultsKey), !uid.isEmpty else { return nil }
        let devices = connected ?? availableDevices()
        guard devices.contains(where: { $0.id == uid && $0.isBluetooth }) else { return uid }
        dlog.info("clearing stale Bluetooth pin '\(uid)' — Bluetooth mics can't be pinned")
        defaults.removeObject(forKey: preferredUIDDefaultsKey)
        return nil
    }

    /// The input Reed will actually record from: the pinned device when a pin
    /// is set and present, the system default otherwise. One definition, so
    /// the menu band, the onboarding advice, and the metrics all agree on
    /// which mic "current" means.
    static func effectiveInput(preferredUID: String?) -> AudioInputDevice? {
        if let uid = preferredUID, !uid.isEmpty,
           let pinned = availableDevices().first(where: { $0.id == uid }) {
            return pinned
        }
        return defaultInput()
    }

    /// The device CoreAudio currently resolves as the system default input.
    static func defaultInput() -> AudioInputDevice? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return device(forDeviceID: deviceID)
    }

    /// Resolves a persisted UID back to the device's current AudioDeviceID —
    /// device IDs aren't stable across reconnects, so pinning re-resolves
    /// this at prewarm time rather than storing the ID directly.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDeviceIDs().first {
            isAlive($0) && stringProperty($0, kAudioDevicePropertyDeviceUID) == uid
        }
    }

    /// The device's own nominal sample rate. The AVAudioInputNode keeps
    /// reporting the PREVIOUS device's format for a beat after the audio unit
    /// is pinned to a new one, so this is the authority on what the hardware
    /// will actually run at — starting the engine on a mismatch fails with
    /// kAudioUnitErr_FormatNotSupported (-10868).
    static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    // MARK: - Private

    private static func inputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }
        return deviceIDs.filter(hasInputStreams)
    }

    /// True when the device has at least one input channel. `dataSize > 0` on
    /// its own is NOT a valid check here — `kAudioDevicePropertyStreamConfiguration`
    /// returns an `AudioBufferList`, whose header alone is non-zero size even
    /// when `mNumberBuffers` is 0, so an output-only device (e.g. "MacBook Pro
    /// Speakers") still reports a non-zero size and was wrongly passing the
    /// old check. Actually parse the buffer list and look for real channels.
    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer) == noErr else {
            return false
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.contains { $0.mNumberChannels > 0 }
    }

    /// True unless CoreAudio explicitly reports the device as dead. A device
    /// this process actively referenced (e.g. pinned as the input unit's
    /// current device) can keep a zombie object alive in *this process's*
    /// enumeration after it's physically disconnected, even though a fresh
    /// process's enumeration never sees it at all — `kAudioDevicePropertyDeviceIsAlive`
    /// is CoreAudio's documented way to tell a live device from that kind of
    /// stale reference. If the property isn't supported, don't block on it.
    private static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAliveValue: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = aliveQueryStatusForTests?(deviceID)
            ?? AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAliveValue)
        guard status == noErr else {
            // On change only: a persistently failing query would otherwise
            // log at UI-tick rate (review 2026-09-04, P1).
            if diagnostics.shouldLog(key: "isAlive-\(deviceID)", message: "status=\(status)") {
                dlog.info("isAlive(\(deviceID)): property query failed, status=\(status) — assuming alive")
            }
            return true
        }
        diagnostics.clear(key: "isAlive-\(deviceID)")
        return isAliveValue != 0
    }

    /// Rejection diagnostics log when a device's verdict changes, not on
    /// every enumeration — the enumeration itself runs at UI-tick rate.
    private static let diagnostics = ChangeOnlyLog()

    /// Test seams (never set by the app): stand in for the two CoreAudio
    /// probes so a dead device and a failing alive query can be exercised on
    /// any Mac, CI included.
    static var hasInputStreamsForTests: ((AudioDeviceID) -> Bool)?
    static var aliveQueryStatusForTests: ((AudioDeviceID) -> OSStatus)?

    /// Display name for a device id — for per-capture logging ("which mic
    /// heard this?" should be one grep, not forensics).
    static func name(forDeviceID deviceID: AudioDeviceID) -> String {
        stringProperty(deviceID, kAudioObjectPropertyName) ?? "device \(deviceID)"
    }

    private static func device(forDeviceID deviceID: AudioDeviceID) -> AudioInputDevice? {
        let name = stringProperty(deviceID, kAudioObjectPropertyName) ?? "<no name>"
        let hasInput = hasInputStreamsForTests?(deviceID) ?? hasInputStreams(deviceID)
        let alive = isAlive(deviceID)
        // Rejections only (review 2026-08-26): this runs on every device
        // enumeration, and callers reach here at UI-tick rate — the healthy
        // line was ~90% of reed.log (2.5 MB/day), which itself rides support
        // reports. A device passing both checks is the boring case; the
        // forensic value is entirely in the one that fails. And a rejection
        // logs once per verdict change, not per tick (review 2026-09-04,
        // P1): a dead device sat in the list and re-logged twenty times a
        // second.
        let verdict = "hasInputStreams=\(hasInput) isAlive=\(alive)"
        if !hasInput || !alive {
            if diagnostics.shouldLog(key: "device-\(deviceID)", message: verdict) {
                dlog.info("device(\(deviceID) '\(name)'): \(verdict)")
            }
        } else {
            diagnostics.clear(key: "device-\(deviceID)")
        }

        guard hasInput,
              alive,
              let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(deviceID, kAudioObjectPropertyName) else { return nil }

        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transportType)

        // CoreAudio synthesizes an aggregate device (transport type "grup")
        // for every process — including this one — that opens the default
        // input+output together (named "CADefaultDeviceAggregate-<pid>-N").
        // It's an ephemeral internal construct, not real hardware, and
        // exposes real input streams so it otherwise passes every check
        // above. `kAudioDeviceTransportTypeAggregate` is a public, documented
        // CoreAudio constant — checking the structural transport type instead
        // of matching this one instance's name string is what makes the
        // filter hold on any Mac. A user-created Aggregate Device (Audio MIDI
        // Setup) would also be excluded, which is the right call here too:
        // not a single physical mic to recommend switching to.
        guard transportType != kAudioDeviceTransportTypeAggregate else { return nil }

        return AudioInputDevice(
            id: uid,
            name: name,
            isBuiltIn: transportType == kAudioDeviceTransportTypeBuiltIn,
            isBluetooth: transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE,
            isContinuity: transportType == kAudioDeviceTransportTypeContinuityCaptureWired
                || transportType == kAudioDeviceTransportTypeContinuityCaptureWireless
        )
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
