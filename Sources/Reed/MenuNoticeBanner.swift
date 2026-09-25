import SwiftUI

/// An amber notice pinned above the status card: a CONDITION the user is
/// living with right now, not a hint they might enjoy.
///
/// Deliberately not the rotating tip row. That slot is styled to be ignorable
/// — correct for "TRY: say compose email…", wrong for "your mic is about to be
/// slow", which is what the first version of this got wrong. It also clamped
/// to two lines and truncated the explanation mid-sentence.
///
/// Shares the error banner's shape so the menu has one visual language for
/// "this affects you", but never goes red and has nothing to dismiss: it
/// clears itself when the condition does, and nothing has failed.
///
/// It may carry a single action. A notice describing a condition the user can
/// end should offer the way out — the first version explained the Bluetooth
/// limitation accurately and then left the reader with nowhere to go.
struct MenuNoticeBanner: View {
    let headline: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?
    /// When non-empty, a device picker renders INSTEAD of the action button:
    /// picking pins the device, which both fixes the condition and clears the
    /// band (the live mic is no longer Bluetooth). The button is the fallback
    /// for when there is nothing to offer — never an empty menu.
    var pickerDevices: [AudioInputDevice] = []
    var onPickDevice: ((AudioInputDevice) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsStyle.amber)
                Text(headline)
                    .font(ReedFont.ui(13, 600))
                    .foregroundStyle(.primary)
                    // Wrap, never truncate — the whole point of this rewrite.
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(ReedFont.ui(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !pickerDevices.isEmpty, let onPickDevice {
                // Native Menu, unlike the dark-glass toasts' hand-built
                // DeviceMenu: the band lives on a standard system-appearance
                // surface, where the native pull-down chrome is the match.
                Menu {
                    ForEach(pickerDevices) { device in
                        Button(device.isBuiltIn ? "\(device.name) (Built-in)" : device.name) {
                            onPickDevice(device)
                        }
                    }
                } label: {
                    Text("Switch to a faster mic…").font(ReedFont.ui(11, 500))
                }
                .controlSize(.small)
                .fixedSize()
                .padding(.top, 2)
            } else if let actionTitle, let action {
                // Bordered, not prominent: this is a way out of a condition,
                // not a failure demanding attention like the error banner's
                // primary action.
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsStyle.amber.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(SettingsStyle.amber.opacity(0.28), lineWidth: 1)
        )
    }
}

/// The conditions worth a banner. One case today; an enum so the next one
/// slots in beside it rather than growing another bespoke surface.
enum MenuNotice {
    /// macOS switches AirPods A2DP->HFP before they can hear, which costs
    /// 0.5-1.5 s on the first dictation. The instruction leads because the pop
    /// is guaranteed and is the only reliable "mic is live" signal; changing
    /// hardware is advice the user may not be able to take, so it comes second.
    static let bluetooth = (
        headline: "AirPods need a moment",
        detail: "Hold the hotkey until you hear the pop - that's when the mic is live. "
              + "A built-in or wired mic starts instantly."
    )
}
