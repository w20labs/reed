import SwiftUI

/// The proactive nudge: shown after a dictation that worked, when the live mic
/// is Bluetooth.
///
/// Distinct from `MicWarningController.show`, which fires after a dictation
/// that FAILED and offers a replacement mic to pin. This one can't offer that,
/// because the fix isn't a pin Reed can make — a Bluetooth mic is only usable
/// as the system input (see `AudioInputDevice.pinnableDevices`), and that
/// choice lives in System Settings. So the actions are "go where the choice
/// is" and "stop telling me".
struct BluetoothNudgeView: View {
    /// Pinnable devices only — built-in and wired. The live AirPods are
    /// deliberately absent: they are what this card is warning about, and a
    /// Bluetooth pin can only record silence.
    let devices: [AudioInputDevice]
    let onSelect: (AudioInputDevice) -> Void
    /// Fallback action, shown only when `devices` is empty (a Mac Studio with
    /// nothing but AirPods connected): there is no mic to offer, so the best
    /// remaining move is the system pane — never an empty menu.
    let onOpenSettings: () -> Void
    let onNeverAgain: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HUDCardHeader(
                headline: "AirPods will slow you down",
                detail: "They take up to a second and a half to switch into microphone "
                      + "mode, and drop more words. Built-in is instant.",
                onDismiss: onDismiss
            )
            if devices.isEmpty {
                HStack(spacing: 8) {
                    HUDCardButton(title: "Open Sound Settings", prominent: true, action: onOpenSettings)
                    HUDCardButton(title: "Don't show again", action: onNeverAgain)
                    Spacer(minLength: 0)
                }
            } else {
                // Picking pins the device: one click and the next dictation is
                // instant — and the AirPods keep playing music at full quality,
                // because Reed stops touching them. The closed label is an
                // action, not a status: the current device is the one thing
                // this list refuses to contain.
                DeviceMenu(devices: devices, currentDeviceID: nil,
                           placeholder: "Switch to a faster mic…", onSelect: onSelect)
                HStack(spacing: 8) {
                    HUDCardButton(title: "Don't show again", action: onNeverAgain)
                    Spacer(minLength: 0)
                }
            }
        }
        .hudCard()
    }
}
