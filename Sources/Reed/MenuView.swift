import AppKit
import KeyboardShortcuts
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var coordinator: Coordinator
    @EnvironmentObject var updater: Updater
    @State private var copied = false
    @State private var copyHovering = false
    /// Cached for the Bluetooth banner — see its `.onAppear`.
    @State private var bluetoothPickerDevices: [AudioInputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

            if let error = coordinator.activeError {
                ErrorBanner(
                    error: error,
                    onAction: { handleErrorAction(error) },
                    onDismiss: { coordinator.activeError = nil },
                    onReport: { coordinator.openReportIssue() }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            // The speech model's download progress / failure + Try again
            // (P15; review 2026-09-03, P1). Nothing while idle.
            SpeechModelDownloadNotice()

            if coordinator.currentMicIsBluetooth {
                MenuNoticeBanner(headline: MenuNotice.bluetooth.headline,
                                 detail: MenuNotice.bluetooth.detail,
                                 actionTitle: "Open Sound Settings",
                                 action: SoundSettings.open,
                                 pickerDevices: bluetoothPickerDevices,
                                 onPickDevice: { coordinator.setPreferredMicrophone(uid: $0.id) })
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    // Enumerated when the banner APPEARS, not per render
                    // (review 2026-08-26): this body re-evaluates on every
                    // published tick — the mic meter at ~10 Hz while
                    // recording — and each evaluation walked the full
                    // CoreAudio device list.
                    .onAppear { bluetoothPickerDevices = AudioInputDevice.pinnableDevices() }
            }

            statusCard
                .padding(.horizontal, 8)

            if !coordinator.lastTranscript.isEmpty {
                lastTranscriptCard
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }

            if DebugMenu.isEnabled {
                DebugMenuSection()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 8)

            VStack(spacing: 0) {
                MenuRow(
                    title: "Settings…",
                    icon: "gearshape",
                    shortcut: nil,
                    action: { coordinator.openSettings() }
                )
                MenuRow(
                    title: "Check for Updates…",
                    icon: "arrow.triangle.2.circlepath",
                    shortcut: nil,
                    action: { updater.checkForUpdates() }
                )
                MenuRow(
                    title: "Quit Reed",
                    icon: "power",
                    shortcut: "⌘Q",
                    action: { NSApplication.shared.terminate(nil) }
                )
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ReedIcon(fill: .reedMark)
                .frame(width: 16, height: 16)

            Text("Reed")
                .font(ReedFont.ui(13, 600))

            Spacer()

            if !appVersion.isEmpty {
                Text("v\(appVersion)")
                    .font(ReedFont.mono(11, 500))   // version = mono badge
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(ReedFont.ui(13, 500))
                    .foregroundStyle(.primary)
                statusSubtitle
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
    }

    private var lastTranscriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LAST DICTATION")
                    .font(ReedFont.ui(10, 600))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                Button(action: copyLastTranscript) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(copied ? "Copied" : "Copy")
                            .font(ReedFont.ui(11, 500))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary.opacity(copyHovering ? 0.7 : 0))
                    }
                }
                .buttonStyle(.plain)
                .onHover { copyHovering = $0 }
                .help("Copy the transcript - handy if it didn't paste at your cursor")
            }

            Text(coordinator.lastTranscript)
                .font(ReedFont.ui(12))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
    }

    private func copyLastTranscript() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(coordinator.lastTranscript, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    /// The error banner's primary action. Settings hosts the microphone and
    /// permission rows, so every actionable error routes there. Clears the
    /// breadcrumb once the user has been taken to the fix.
    private func handleErrorAction(_ error: DictationError) {
        switch error.action {
        case .openSettings:
            coordinator.openSettings()
        case .openPermissions:
            coordinator.openSettings(tab: .permissions)
        case .none:
            break
        }
        coordinator.activeError = nil
    }

    // MARK: - State-driven content

    // One coherent, monochrome icon family — charcoal/secondary throughout
    // (recording reads through motion, per Reed's "motion, not color"). Only a
    // genuine error breaks monochrome, because that's worth the alarm.
    @ViewBuilder
    private var statusIcon: some View {
        switch coordinator.state {
        // A notice ("Nothing to write") is a non-event by the time the menu is
        // open — present it as plain Ready, not as a lingering outcome. An
        // error renders as Ready too: the banner above owns the error story,
        // and the card echoing it (truncated, red) said the same thing twice.
        case .idle, .notice, .error:
            statusGlyph("mic", weight: .medium).foregroundStyle(.secondary)
        case .warming, .recording:
            statusGlyph("mic.fill", weight: .medium)
                .foregroundStyle(.primary)
                .symbolEffect(.pulse, options: .repeating)
        case .preparingModel, .transcribing:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.secondary)
        case .injecting:
            statusGlyph("checkmark", weight: .semibold).foregroundStyle(.primary)
        }
    }

    private func statusGlyph(_ name: String, weight: Font.Weight) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: weight))
    }

    private var statusTitle: String {
        switch coordinator.state {
        case .idle, .notice, .error: return "Ready"
        case .warming where coordinator.micIsPreparing: return "Preparing mic…"
        case .warming, .recording: return "Listening"
        case .preparingModel: return "Preparing speech model…"
        case .transcribing: return "Transcribing…"
        case .injecting: return "Pasting…"
        }
    }

    // The shortcut glyph renders in Geist Mono inside the otherwise-Geist line.
    private var statusSubtitle: Text {
        // A default install has NO recorded combo — the trigger is the bare
        // ⌃⌥ hold, which lives in PushToTalkTrigger, not KeyboardShortcuts.
        // Falling back to a literal "no shortcut set" told every fresh
        // install to "Hold no shortcut set to dictate" (review 2026-08-26).
        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation)?.description
            ?? PushToTalkTrigger.current.keycap
        func plain(_ string: String) -> Text { Text(string).font(ReedFont.ui(11)) }
        func mono(_ string: String) -> Text { Text(string).font(ReedFont.mono(11, 500)) }
        switch coordinator.state {
        case .idle, .notice, .error: return plain("Hold ") + mono(shortcut) + plain(" to dictate")
        case .warming, .recording: return plain("Release ") + mono(shortcut) + plain(" to transcribe")
        case .preparingModel: return plain("One-time model preparation - next dictations are instant")
        case .transcribing: return plain("Transcribing on your Mac…")
        case .injecting: return plain("Inserting at cursor")
        }
    }

    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
}

// MARK: - MenuRow

/// A menubar-style button row that mimics native NSMenuItem look: borderless,
/// full-width, with a subtle hover background.
private struct MenuRow: View {
    let title: String
    let icon: String?
    let shortcut: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .center)
                }
                Text(title)
                    .font(ReedFont.ui(13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(ReedFont.mono(12))   // shortcut = mono
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : .clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// ErrorBanner lives in MenuErrorBanner.swift (split for the swiftlint
// file-length cap).
