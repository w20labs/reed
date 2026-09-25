import KeyboardShortcuts
import SwiftUI

/// Final step, with one job (design: "Onboarding · You're done"): the
/// supervised, pre-warmed first dictation. A left-aligned header and the
/// auto-focused Try-it field as the hero — no circle ceremony, no recap
/// checklist, no teaser card (decision-tree Q4: never sell what cannot
/// transact). When text lands, the page responds — celebration at the
/// moment that earns it, not before.
@MainActor
struct DoneStep: View {
    var audio: OnboardingAudio?

    @State private var visible = false
    @State private var prewarmed = false
    @State private var tryText = ""
    /// Flipped when text first lands (dictated — or typed; close enough) so
    /// the caption can confirm the loop closed.
    @State private var landed = false
    @FocusState private var tryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reed is ready.")
                .font(ReedFont.ui(26, 600))
                .tracking(-0.5)
                .foregroundStyle(Onb.ink)

            Text("Hold \(hotkeyDisplay) in any app, talk, release - clean text lands at your cursor. Fully private, on your Mac.")
                .font(ReedFont.ui(14))
                .foregroundStyle(Onb.slate)
                .lineSpacing(2)
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.top, 10)

            tryItField
                .frame(maxWidth: 460, alignment: .leading)
                .padding(.top, 26)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(visible ? 1.0 : 0.0)
        .offset(y: visible ? 0 : 6)
        .onAppear {
            // Silent pre-warm (design: "Onboarding · Done — pre-warmed
            // try-it"): if the live input is Bluetooth, pay the ~1.5s profile
            // switch NOW, HAL-muted and indicator-off, while the user reads —
            // so "Try it — right here" resumes warm at ~130ms instead of
            // eating their first words. No-op for wired/built-in; a failure
            // silently leaves the honest cold path.
            if !prewarmed {
                prewarmed = true
                audio?.prewarmHold()
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                visible = true
            }
            // Async hop lets the field land in the hierarchy first (same
            // fix as MagicLinkSignInForm.focusCurrentField) — assigning
            // focus synchronously in onAppear is unreliable here.
            DispatchQueue.main.async {
                tryFocused = true
            }
        }
        .onChange(of: tryText) { _, new in
            if !new.isEmpty { landed = true }
        }
    }

    // MARK: - Try it

    private var tryItField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it - right here")
                .font(ReedFont.ui(12, 500))
                .foregroundStyle(Onb.slate)

            TextField("", text: $tryText, prompt: placeholder, axis: .vertical)
                .textFieldStyle(.plain)
                .font(ReedFont.ui(13))
                .foregroundStyle(Onb.ink)
                .lineLimit(3...5)
                .focused($tryFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 84, alignment: .top)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Onb.card)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tryFocused ? Onb.green : Onb.hair, lineWidth: 1)
                }
                // E1 focus glow — this is the surface's auto-focused control.
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tryFocused ? Onb.green.opacity(0.18) : .clear)
                        .padding(-3)
                }

            if landed {
                (Text("✓ ").foregroundColor(Onb.green).fontWeight(.bold)
                 + Text("That's dictation - and it works exactly like this in every app on your Mac.")
                    .foregroundColor(Onb.ink2))
                    .font(ReedFont.ui(12.5, 500))
                    .fixedSize(horizontal: false, vertical: true)
            } else if tryFocused {
                Text("Already focused - just hold and talk.")
                    .font(ReedFont.ui(12))
                    .foregroundStyle(Onb.mute)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Click here, then hold and talk.")
                    .font(ReedFont.ui(12))
                    .foregroundStyle(Onb.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // The sub already teaches the gesture, so the placeholder carries only
    // the "say this" — copy said once (design note).
    private var placeholder: Text {
        Text("Say “this is a test” - your words land in this field")
    }

    /// The gesture as configured: the recorded combo if one exists, else the
    /// ⌃⌥ hold default (never a phantom key like the old "⌃⌥D" fallback).
    private var hotkeyDisplay: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) {
            return shortcut.description
        }
        let trigger = PushToTalkTrigger.current
        return trigger.isHold ? trigger.keycap : PushToTalkTrigger.controlOption.keycap
    }
}
