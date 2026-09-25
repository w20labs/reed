import SwiftUI

/// The Settings ▸ Dictation microphone picker.
///
/// Its own view rather than an inline row because it carries a conditional
/// second line: the list deliberately omits Bluetooth mics (Reed cannot pin
/// them — see `AudioInputDevice.pinnableDevices`), and an unexplained absence
/// reads as a bug. "Where are my AirPods?" is a worse first impression than
/// the limitation itself, so whenever a Bluetooth input is actually connected
/// the row says why they're missing and links to the one place the choice can
/// be made.
struct MicrophoneRow: View {
    @ObservedObject var coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpace.sm) {
            PaneRow(icon: "mic", title: "Microphone",
                    subtitle: "Built-in starts instantly; wired is close behind.") {
                Picker("", selection: selection) {
                    Text(systemDefaultLabel).tag("")
                    ForEach(AudioInputDevice.pinnableDevices()) { device in
                        Text(device.isBuiltIn ? "\(device.name) (Recommended)" : device.name)
                            .tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
            }
            if AudioInputDevice.hasBluetoothInput() {
                bluetoothNote
            }
        }
    }

    /// Rendered as markdown so the link wraps inline with the sentence — a
    /// trailing `Button` would either get squeezed by the wrapping text or
    /// need its own line, and this is one thought, not two.
    private var bluetoothNote: some View {
        Text(.init(
            "Bluetooth mics can't be chosen here - macOS only hands them to an app "
            + "when they're your Mac's input. [Open Sound Settings](reed://sound-settings)"
        ))
        .font(SettingsType.rowSubtitle)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        // Aligns under the row's title: PaneRow's own leading padding, plus
        // the icon's width, plus its icon-to-title spacing.
        .padding(.leading, SettingsSpace.lg + 24 + SettingsSpace.md)
        .padding(.trailing, SettingsSpace.lg)
        // Matches PaneRow's own bottom inset so this note doesn't sit flush
        // against the card's rounded bottom edge.
        .padding(.bottom, SettingsSpace.md)
        .environment(\.openURL, OpenURLAction { _ in
            SoundSettings.open()
            return .handled
        })
    }

    private var selection: Binding<String> {
        Binding(
            get: { coordinator.preferredMicrophoneUID ?? "" },
            set: { coordinator.setPreferredMicrophone(uid: $0.isEmpty ? nil : $0) }
        )
    }

    /// Names the device the default currently resolves to, so "System Default"
    /// isn't an unknown. This is also the only place AirPods still appear by
    /// name — honestly, because it is genuinely what Reed will record from.
    private var systemDefaultLabel: String {
        guard let name = AudioInputDevice.defaultInput()?.name else { return "System Default" }
        return "System Default (\(name))"
    }
}
