import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI

/// The sidebar categories (design/hud-design-system.html → Settings). Each maps
/// to one pane.
enum SettingsTab: String, CaseIterable, Identifiable {
    case dictation, cleanup, permissions, privacy, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        // Its own tab (design: "Settings › Cleanup", 2026-08-08) — it kept
        // reading as a sub-option of the speech model instead of the
        // independent on/off it is.
        case .cleanup: return "Cleanup"
        case .permissions: return "Permissions"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .dictation: return "keyboard"
        case .cleanup: return "sparkles"
        case .permissions: return "lock.shield"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var coordinator: Coordinator

    // Telemetry is off by default and Reed never asks (2026-09-14): these two
    // toggles are the only way it gets turned on.

    @State var micGranted: Bool = false
    @State var axGranted: Bool = false
    @State var selected: SettingsTab = .dictation
    /// About → Acknowledgements. A sheet on the Settings window, so the reader
    /// needs no window of its own.
    @State var showingAcknowledgements = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SettingsStyle.pane)
                .onReceive(coordinator.$requestedSettingsTab) { requested in
                    // Error actions deep-link a pane (e.g. permission errors →
                    // Permissions); consume the request so reopening Settings
                    // later lands on the default again.
                    guard let requested else { return }
                    selected = requested
                    coordinator.requestedSettingsTab = nil
                }
        }
        // ~10% larger than the base 720×560 (via window + spacing, not scaling
        // or fonts); the NSWindow contentRect in Coordinator.openSettings matches.
        .frame(width: 792, height: 616)
        .tint(SettingsStyle.charcoal)
        // Default to the ramp's hint/footnote size (SF Pro 13) so anything
        // unstyled matches the type ramp; explicit SettingsType fonts still win.
        .font(ReedFont.ui(13))
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refreshPermissions()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                SidebarItem(icon: tab.icon, title: tab.title, selected: selected == tab) {
                    selected = tab
                }
            }
            Spacer(minLength: 0)
        }
        // Extra top padding clears the floating traffic-light buttons now that
        // the title bar is hidden (Coordinator fullSizeContentView) — 40, the
        // one blessed window-chrome value here (the rail's own insets are on
        // the scale).
        .padding(.horizontal, SettingsSpace.md)
        .padding(.bottom, SettingsSpace.md)
        .padding(.top, 40)
        .frame(width: 202)
        .frame(maxHeight: .infinity)
        .background(SettingsStyle.charcoal)
    }

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = TextInjector.ensureAccessibilityPermission(prompt: false)
    }
}

extension SettingsView {

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }
}

// MARK: - StatusPill

struct StatusPill: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: SettingsSpace.xs) {
            // The glyph is a filled disc — a shape, so it keeps the green.
            // Only the word takes ink: tinting the whole HStack turned the
            // disc itself black.
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(granted ? SettingsStyle.green : SettingsStyle.amber)
            Text(granted ? "Granted" : "Needed")
                .font(ReedFont.ui(13, 500))
                .foregroundStyle(granted ? SettingsStyle.onGreen : SettingsStyle.amber)
        }
        .padding(.horizontal, SettingsSpace.sm)
        .padding(.vertical, SettingsSpace.xs)
        .background((granted ? SettingsStyle.green : SettingsStyle.amber).opacity(0.12), in: Capsule())
    }
}
