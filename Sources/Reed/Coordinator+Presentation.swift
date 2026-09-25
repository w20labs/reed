import AppKit
import SwiftUI

/// Presentation helpers split out of Coordinator.swift (file_length): the
/// menubar glyph for each pipeline state, and the completion pop sound.
extension Coordinator {
    var menuIcon: String {
        switch state {
        case .idle, .notice: return "mic"
        case .warming: return "mic.slash"
        case .recording: return "mic.fill"
        case .preparingModel, .transcribing, .injecting: return "waveform"
        case .error: return "exclamationmark.triangle"
        }
    }

    func playPopSound() {
        guard let sound = Self.dictationCueSound else {
            log.error("Dictation cue sound not loaded")
            return
        }
        let didPlay = sound.play()
        log.info("Dictation cue sound play() returned \(didPlay)")
    }

    /// Bundled in Resources/Sounds and copied to Contents/Resources/Sounds by
    /// build-app.sh (see that file: Bundle.module's macOS resource path is
    /// broken, so this — like the Fonts folder — is loaded via Bundle.main
    /// instead). Cached so repeat plays don't re-hit disk or Bundle lookup.
    private static let dictationCueSound: NSSound? = {
        guard let url = Bundle.main.url(
            forResource: "pop",
            withExtension: "wav",
            subdirectory: "Sounds"
        ) else {
            return nil
        }
        return NSSound(contentsOf: url, byReference: true)
    }()

    /// Where bug reports go now that Reed has no server of its own: the
    /// repository's reproducible-bug issue form (CONTRIBUTING.md).
    static let reportIssueURL = URL(string: "https://github.com/w20labs/reed/issues/new?template=bug.yml")!

    /// Menu error banner → "Report this" and Settings › About → "Report an
    /// issue": open the bug form in the browser.
    func openReportIssue() {
        NSWorkspace.shared.open(Self.reportIssueURL)
    }

    func openSettings(tab: SettingsTab? = nil) {
        if let tab { requestedSettingsTab = tab }
        if settingsWindow == nil {
            let window = NSWindow(
                // ~10% larger than base (via window + spacing, not scaling or
                // fonts); matches SettingsView's frame.
                contentRect: NSRect(x: 0, y: 0, width: 792, height: 616),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.titlebarAppearsTransparent = true
            // Hide the title-bar strip: content runs edge-to-edge to the top and
            // the traffic-light buttons float over the sidebar. SettingsView pads
            // the sidebar top so the nav clears them.
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            // The redesign commits to a warm-greige + charcoal light palette
            // (design/hud-design-system.html), so pin the window to aqua rather
            // than let system dark mode invert the surfaces.
            window.appearance = NSAppearance(named: .aqua)
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(
                rootView: SettingsView().environmentObject(self)
            )
            // When the window closes, revert to .accessory so the app
            // disappears from the Dock again (it's a menubar app).
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
