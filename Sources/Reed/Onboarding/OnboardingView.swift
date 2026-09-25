import KeyboardShortcuts
import SwiftUI

/// First-launch onboarding window. Sidebar layout: brand mark + step list
/// on the left; step content + Back/Continue footer on the right.
///
/// The Next button is disabled until the current step's prerequisite is
/// met (mic granted, AX granted, speech model ready). Welcome, Hotkey, Done,
/// and the optional Cleanup step always allow advancing.
struct OnboardingView: View {
    @StateObject var state = OnboardingState()
    /// Audio actions for the Microphone step's Bluetooth advice and the Done
    /// step's silent pre-warm. Optional so previews/tests need no CoreAudio.
    var audio: OnboardingAudio?
    var onFinish: () -> Void

    /// Re-evaluated each tick because permission state and KeyboardShortcuts'
    /// UserDefault writes aren't events we can subscribe to.
    @State private var canAdvance = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 256)
                .frame(maxHeight: .infinity)
                .background(Onb.charcoal)

            VStack(spacing: 0) {
                stepBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 42)
                    .padding(.top, 40)

                footer
                    .padding(.horizontal, 42)
                    .padding(.vertical, 16)
                    .background(Onb.paper)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Onb.line).frame(height: 1)
                    }
            }
            .frame(maxWidth: .infinity)
            .background(Onb.card)
        }
        .frame(width: 880, height: 640)
        // Charcoal is the structural accent (matching Settings) — so
        // borderedProminent buttons (Continue, Grant)
        // inherit charcoal instead of the system blue. Green stays a spark.
        .tint(Onb.charcoal)
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            canAdvance = state.canAdvance(from: state.step)
        }
        .onChange(of: state.step) { _, _ in
            canAdvance = state.canAdvance(from: state.step)
        }
        .onAppear { canAdvance = state.canAdvance(from: state.step) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ReedAppIcon()
                    .frame(width: 30, height: 30)
                Text("Set up Reed")
                    .font(ReedFont.ui(15.5, 600))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 26)
            .padding(.top, 30)
            .padding(.bottom, 30)

            VStack(spacing: 2) {
                ForEach(state.visibleSteps, id: \.self) { s in
                    sidebarRow(for: s)
                }
            }
            .padding(.horizontal, 18)

            Spacer()
        }
    }

    private func sidebarRow(for s: OnboardingState.Step) -> some View {
        let isCurrent = s == state.step
        let isPast = s.rawValue < state.step.rawValue
        // Progress display, NOT navigation (founder decision 2026-08-07):
        // clicking a step used to jump there, which let "Microphone" leap
        // straight over Welcome's Continue — the terms-acceptance act (P12).
        // Movement happens only through Back/Continue, whose handlers own the
        // gates; the rail just tells you where you are.
        return HStack(spacing: 13) {
            StepIndicator(isCurrent: isCurrent, isPast: isPast)
            Text(stepLabel(for: s))
                .font(ReedFont.ui(13.5, isCurrent ? 500 : 400))
                .foregroundStyle(isCurrent ? Color.white : (isPast ? Color.white.opacity(0.72) : Color.white.opacity(0.5)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.white.opacity(0.12) : .clear)
        }
    }

    private func stepLabel(for s: OnboardingState.Step) -> String {
        switch s {
        case .welcome:       return "Welcome"
        case .microphone:    return "Microphone"
        case .accessibility: return "Accessibility"
        case .hotkey:        return "Hotkey"
        case .onDeviceSetup: return "Speech model"
        case .cleanup:       return "Cleanup"
        case .done:          return "You're done"
        }
    }

    // MARK: - Step body

    @ViewBuilder
    private var stepBody: some View {
        switch state.step {
        case .welcome:       WelcomeStep()
        case .microphone:    MicrophoneStep(audio: audio, onGranted: { state.advance() })
        case .accessibility: AccessibilityStep(onGranted: { state.advance() })
        case .hotkey:        HotkeyStep()
        case .onDeviceSetup: OnDeviceSetupStep()
        case .cleanup:       CleanupStep()
        case .done:          DoneStep(audio: audio)
        }
    }

    // MARK: - Footer

    /// Done hides Back: there is nothing to revisit once setup has proven
    /// itself.
    private var footer: some View {
        HStack {
            if state.step.isFirst {
                // The terms footnote lives in the Back link's slot — dead
                // space on Welcome — directly adjacent to Continue, whose
                // click is the affirmative act (design P12). No checkbox and
                // no separate screen: Welcome's Continue is the acceptance.
                markdownText(
                    "By continuing, you agree to the [Terms of Service](\(ReedLinks.terms)) "
                    + "and acknowledge the [Privacy Policy](\(ReedLinks.privacy)).")
                    .font(ReedFont.ui(11))
                    .foregroundStyle(Onb.slate)
                    .tint(Onb.ink)
                    .lineSpacing(2)
                    .frame(maxWidth: 340, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    state.back()
                } label: {
                    Text("← Back")
                        .font(ReedFont.ui(13))
                        .foregroundStyle(Onb.slate)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .opacity(state.step.isLast ? 0 : 1)
                .disabled(state.step.isLast)
            }

            Spacer()

            Button(state.step.isLast ? "Get started" : "Continue") {
                if state.step.isFirst { TermsAcceptance.record() }
                if state.step.isLast {
                    OnboardingState.markComplete()
                    onFinish()
                } else {
                    state.advance()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(OnbPrimaryButtonStyle())
            .disabled(!canAdvance)
        }
    }
}

// MARK: - Step indicator (sidebar circle)

private struct StepIndicator: View {
    let isCurrent: Bool
    let isPast: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(borderColor, lineWidth: 1.2)
                .background(Circle().fill(fillColor))
                .frame(width: 18, height: 18)
            if isPast {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Onb.onGreen)
            } else if isCurrent {
                Circle()
                    .fill(Onb.green)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var borderColor: Color {
        if isPast || isCurrent { return Onb.green }
        return Color.white.opacity(0.28)   // todo — subtle on the charcoal rail
    }
    private var fillColor: Color {
        if isPast { return Onb.green }
        return .clear
    }
}
