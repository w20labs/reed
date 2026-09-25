import AppKit
import SwiftUI

/// Accessibility permission. No programmatic-grant path — we deep-link to
/// System Settings and poll once per second for the user flipping the
/// Reed toggle.
struct AccessibilityStep: View {
    var onGranted: () -> Void
    @State private var granted = TextInjector.ensureAccessibilityPermission(prompt: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Accessibility access")
                .font(ReedFont.ui(26, 600))
                .tracking(-0.5)
                .foregroundStyle(Onb.ink)
            Text("To insert the transcribed text at your cursor, Reed needs the Accessibility permission. macOS requires this for any app that types on your behalf.")
                .font(ReedFont.ui(14))
                .foregroundStyle(Onb.slate)
                .lineSpacing(2)
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 12) {
                StatusBanner(
                    granted: granted,
                    pendingIcon: "accessibility",
                    doneText: "Accessibility access granted",
                    pendingText: "Accessibility access not granted yet"
                )

                if !granted {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Open System Settings → Accessibility") {
                            // Deep link only — no AXIsProcessTrusted prompt.
                            // The system alert duplicates this exact button
                            // ("Open System Settings") and never dismisses
                            // itself once shown, even after access is granted.
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .buttonStyle(OnbSecondaryButtonStyle())
                        Text("Find Reed in the list and turn it on. This will update automatically.")
                            .font(ReedFont.ui(12))
                            .foregroundStyle(Onb.mute)
                    }
                }
            }
            .frame(maxWidth: 500, alignment: .leading)
            .padding(.top, 28)

            Spacer()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            let now = TextInjector.ensureAccessibilityPermission(prompt: false)
            if now != granted {
                granted = now
                if now { onGranted() }
            }
        }
    }
}
