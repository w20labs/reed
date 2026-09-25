import AppKit
import AVFoundation
import SwiftUI

/// Microphone permission. One card, two rows (design: "Onboarding ·
/// Microphone"): a status row whose tint lives only in the icon, a hairline
/// divider, and a second row that morphs with state — grant action, System
/// Settings deep-link, or the "Dictate with" picker. We poll once per second
/// to catch changes made in System Settings without the user touching us
/// first.
struct MicrophoneStep: View {
    var audio: OnboardingAudio?
    var onGranted: () -> Void
    @State private var status = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var advancedOnce = false
    @State private var current: AudioInputDevice?
    @State private var pinnable: [AudioInputDevice] = []

    private var granted: Bool { status == .authorized }

    /// Wired/built-in users keep the instant auto-advance; a Bluetooth input
    /// cancels it so the mic row's footnote gets its moment.
    static func shouldAutoAdvance(current: AudioInputDevice?) -> Bool {
        current?.isBluetooth != true
    }

    /// What the "Dictate with" menu offers: the SYSTEM DEFAULT (the "no pin"
    /// option — listed even while a pin points elsewhere, or the way back to
    /// it disappears) plus every pinnable device. Pure, so the composition is
    /// testable without CoreAudio.
    static func pickerOptions(systemDefault: AudioInputDevice?, pinnable: [AudioInputDevice]) -> [AudioInputDevice] {
        guard let systemDefault, !pinnable.contains(where: { $0.id == systemDefault.id }) else { return pinnable }
        return [systemDefault] + pinnable
    }

    /// The callout button's one-click target: the best instant-start mic on
    /// this Mac — built-in preferred, else the first wired device (a Mac
    /// Studio has no built-in mic but may well have USB mics on the desk).
    /// Continuity iPhone mics are never recommended. Nil only when nothing
    /// qualifies — then the button is omitted and the sentence stands alone.
    static func calloutFallback(pinnable: [AudioInputDevice]) -> AudioInputDevice? {
        pinnable.first { $0.isBuiltIn } ?? pinnable.first { !$0.isContinuity }
    }

    private func handleGranted() {
        refreshDevices()
        guard !advancedOnce, Self.shouldAutoAdvance(current: current) else { return }
        advancedOnce = true
        onGranted()
    }

    @State private var systemDefault: AudioInputDevice?

    private func refreshDevices() {
        guard granted, let audio else { return }
        current = audio.currentInput()
        systemDefault = audio.systemDefault()
        pinnable = audio.pinnable()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Microphone access")
                .font(ReedFont.ui(26, 600))
                .tracking(-0.5)
                .foregroundStyle(Onb.ink)
            Text("To transcribe your speech, Reed needs the Microphone permission. macOS requires this for any app that listens for audio.")
                .font(ReedFont.ui(14))
                .foregroundStyle(Onb.slate)
                .lineSpacing(2)
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.top, 10)

            card
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.top, 28)

            Spacer()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            let now = AVCaptureDevice.authorizationStatus(for: .audio)
            if now != status {
                status = now
                if now == .authorized { handleGranted() }
            }
            // AirPods connect/disconnect mid-step; keep the row honest.
            refreshDevices()
        }
        .onAppear { refreshDevices() }
    }

    /// Permission and mic choice are two facets of one subject, so they share
    /// a container but not a surface: the tint stays confined to the status
    /// icon. StatusBanner's full-width tinted fill is retired on this step.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(granted ? Onb.green : Onb.orange)
                    Image(systemName: granted ? "checkmark" : "mic.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(granted ? Onb.onGreen : .white)
                }
                .frame(width: 20, height: 20)
                Text(granted
                     ? "Microphone access granted"
                     : (status == .denied || status == .restricted
                        ? "Reed is blocked in System Settings"
                        : "Microphone access not granted yet"))
                    .font(ReedFont.ui(13.5, 600))
                    .foregroundStyle(Onb.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Rectangle().fill(Onb.hair).frame(height: 1)

            Group {
                if granted {
                    micRow
                } else if status == .denied || status == .restricted {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Open System Settings → Microphone") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                        .buttonStyle(OnbSecondaryButtonStyle())
                        Text("Find Reed and turn it on. This will update automatically.")
                            .font(ReedFont.ui(12))
                            .foregroundStyle(Onb.mute)
                    }
                } else {
                    Button("Grant microphone access") {
                        AVCaptureDevice.requestAccess(for: .audio) { ok in
                            Task { @MainActor in
                                status = ok ? .authorized : .denied
                                if ok { handleGranted() }
                            }
                        }
                    }
                    .buttonStyle(OnbSecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if granted, current?.isBluetooth == true {
                bluetoothCallout
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Onb.card)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Onb.hair, lineWidth: 1)
        )
    }

    /// The Bluetooth warning as a full-bleed amber callout row (design:
    /// "Onboarding · Microphone — the mic row"; P6). Two quieter drafts were
    /// rejected as ignorable — the auto-advance stops the page for this line,
    /// so it has to look like the reason the page stopped. The remedy is a
    /// button: one click pins the built-in mic and the row dismisses itself.
    private var bluetoothCallout: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Onb.orange)
                    .padding(.top, 2)
                // Consequence first — an info-tone line ("takes a moment to
                // wake up") didn't read as a problem (founder review). The
                // concatenation needs foregroundColor: per-segment styling
                // is the one thing foregroundStyle can't do on Text.
                (Text("Dictation will be slow to start with \(current?.name ?? "a Bluetooth mic"). ")
                    .font(ReedFont.ui(12.5, 600))
                    .foregroundColor(Onb.ink2)
                 + Text("Every press waits a couple of seconds while the mic wakes up.")
                    .font(ReedFont.ui(12.5))
                    .foregroundColor(Onb.slate))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let remedy = Self.calloutFallback(pinnable: pinnable) {
                Button("Use \(remedy.name) instead") {
                    audio?.pin(remedy.id)
                    refreshDevices()
                }
                .buttonStyle(OnbSecondaryButtonStyle())
                .padding(.leading, 23)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Onb.orangeBg)
    }

    /// The mic choice as a SETTING (design: "Onboarding · Microphone — the
    /// mic row"). One always-present row in System Settings' own idiom; the
    /// Bluetooth warning lives in `bluetoothCallout`, not here. Choosing a
    /// pinnable device pins it; choosing the system default clears the pin.
    private var micRow: some View {
        HStack {
            Text("Dictate with")
                .font(ReedFont.ui(13, 500))
                .foregroundStyle(Onb.ink)
            Spacer(minLength: 12)
            Menu {
                ForEach(Self.pickerOptions(systemDefault: systemDefault, pinnable: pinnable)) { device in
                    Button {
                        // Choosing the system default means "no pin" —
                        // whatever its transport; pins exist to divert
                        // FROM the default, never to restate it.
                        audio?.pin(device.id == systemDefault?.id ? nil : device.id)
                        refreshDevices()
                    } label: {
                        Text(device.id == current?.id ? "✓ \(device.name)" : device.name)
                    }
                }
            } label: {
                Text(current?.name ?? "System Default")
                    .font(ReedFont.ui(12.5))
            }
            .fixedSize()
        }
    }
}
