import AppKit
import KeyboardShortcuts
import SwiftUI

/// Hotkey step. Reed defaults to a bare ⌃⌥ *hold*, so this step is never
/// blocking — the user keeps the default and hits Continue, or clicks the
/// field to record a combo (which overrides the hold). One labeled control:
/// `HotkeyRecorderField`, the same recorder Settings → Dictation uses.
struct HotkeyStep: View {
    @State private var custom = KeyboardShortcuts.getShortcut(for: .toggleDictation)
    @State private var recording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pick a hotkey")
                .font(ReedFont.ui(26, 600))
                .tracking(-0.5)
                .foregroundStyle(Onb.ink)
            Text("Hold ⌃⌥ (control + option) anywhere to dictate; release to transcribe. Keep this default, or record your own combo like ⌃⌥R.")
                .font(ReedFont.ui(14))
                .foregroundStyle(Onb.slate)
                .lineSpacing(2)
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 0) {
                Text("Your hotkey")
                    .font(ReedFont.ui(12, 500))
                    .foregroundStyle(Onb.slate)

                HotkeyRecorderField(layout: .wide, custom: $custom) { recording = $0 }
                    .padding(.top, 6)

                Text("Press ⌃, ⌥, or ⌘ with a key - like ⌃⌥R. Or press ⌃⌥, ⌃⌘, or ⌥⌘. Change it anytime in Settings.")
                    .font(ReedFont.ui(12))
                    .foregroundStyle(Onb.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                if custom != nil, !recording {
                    Button("Use ⌃⌥ instead") {
                        PushToTalkTrigger.controlOption.apply()
                        custom = nil
                    }
                    .buttonStyle(.plain)
                    .font(ReedFont.ui(12, 500))
                    .foregroundStyle(Onb.ink)
                    .underline()
                    .padding(.top, 10)
                }
            }
            .frame(maxWidth: 340, alignment: .leading)
            .padding(.top, 26)

            Spacer()
        }
    }
}
