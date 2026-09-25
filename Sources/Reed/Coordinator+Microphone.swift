import Foundation

/// Bluetooth/mic-warning handling: split out of Coordinator.swift to keep it
/// under the swiftlint file-length cap (see Coordinator+ModeHotkeys.swift for
/// the same pattern).
extension Coordinator {
    /// Sets the preferred input device (nil = system default) from the menu
    /// bar picker, Settings picker, or the mic-warning toast — persists it and
    /// tells the recorder to re-pin on the next recording rather than waiting
    /// for an unrelated device notification.
    func setPreferredMicrophone(uid: String?) {
        log.info("setPreferredMicrophone: \(uid ?? "<system default>")")
        preferredMicrophoneUID = uid
        if let uid, !uid.isEmpty {
            UserDefaults.standard.set(uid, forKey: AudioInputDevice.preferredUIDDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AudioInputDevice.preferredUIDDefaultsKey)
        }
        recorder.applyPreferredInputChange()
    }

    func showMicWarning() {
        let isBluetooth = currentMicIsBluetooth
        log.info("showing mic warning — released before real signal confirmed (bluetooth=\(isBluetooth))")
        // "Slow to connect" was wrong for the case that actually happens: the
        // device delivers ZERO frames, not late ones, so no amount of waiting
        // helps and the user has already spent seconds talking to nothing.
        let detail = isBluetooth
            ? "Reed got no audio at all from this Bluetooth mic. macOS often won't "
              + "hand it over to an app directly - select it as your Mac's input in "
              + "Sound settings, or pick another mic below."
            : "Try again, or switch mics below."
        micWarning.show(
            headline: "We couldn't hear you",
            detail: detail,
            devices: AudioInputDevice.availableDevices(),
            currentDeviceID: preferredMicrophoneUID ?? AudioInputDevice.defaultInput()?.id,
            onSelect: { [weak self] device in self?.setPreferredMicrophone(uid: device.id) }
        )
    }

    /// Fires the proactive Bluetooth nudge, if this is a moment for it.
    ///
    /// Called only from `finishDictation`, i.e. after a dictation that reached
    /// the end of its pipeline. Never mid-dictation, and never after a failed
    /// one — that path already shows the mic-warning toast, which says
    /// something more specific and would collide with this.
    func maybeNudgeAboutBluetooth() {
        guard currentMicIsBluetooth, bluetoothNudge.shouldShow() else { return }
        bluetoothNudge.recordShown()
        micWarning.showBluetoothNudge(
            // Built-in and wired only — never a Bluetooth entry. Picking pins
            // the device, which also stops the nudge recurring: the live mic
            // is no longer Bluetooth.
            devices: AudioInputDevice.pinnableDevices(),
            onSelect: { [weak self] device in self?.setPreferredMicrophone(uid: device.id) },
            onOpenSettings: SoundSettings.open,
            onNeverAgain: { [weak self] in self?.bluetoothNudge.suppressForever() }
        )
    }

    /// Whether the mic actually in use (preferred pin, or system default if
    /// unset) is Bluetooth — used only to tailor the mic-warning toast's
    /// copy (see `showMicWarning`), not to gate whether it shows at all: the
    /// same "released before anything was captured" problem can happen on
    /// any mic (disconnected USB device, driver hiccup, etc.), not just
    /// Bluetooth's SCO handshake.
    var currentMicIsBluetooth: Bool {
        currentInputDevice?.isBluetooth ?? false
    }

    /// The device Reed will actually record from right now (pin, else default).
    var currentInputDevice: AudioInputDevice? {
        AudioInputDevice.effectiveInput(preferredUID: preferredMicrophoneUID)
    }
}
