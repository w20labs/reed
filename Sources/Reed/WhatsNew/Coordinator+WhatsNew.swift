import AppKit
import SwiftUI

/// What's-new window plumbing. Symmetric with [[Coordinator+Onboarding]];
/// lives in its own file so Coordinator.swift stays under the swiftlint
/// file-length cap. The sheet only ever fires when [[WhatsNew.pending]] is
/// non-nil, and it self-marks-seen on close so a single dismissal is enough.
extension Coordinator {
    /// Opens the What's New sheet for the running version, if there is one
    /// the user hasn't seen yet. Safe to call unconditionally — it no-ops
    /// when there's nothing to show.
    func showWhatsNewIfNeeded() {
        guard let entry = WhatsNew.pending() else { return }
        openWhatsNew(entry: entry)
    }

    private func openWhatsNew(entry: WhatsNewEntry) {
        if whatsNewWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            // Real title (not empty) so VoiceOver and the Window menu have
            // something to read. titlebarAppearsTransparent hides the chrome
            // visually, but the accessibility label still resolves.
            window.title = "What's New"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(
                rootView: WhatsNewView(
                    entry: entry,
                    onOpenSettings: { [weak self] in
                        self?.whatsNewWindow?.close()
                        self?.openSettings()
                    },
                    onDismiss: { [weak self] in
                        self?.whatsNewWindow?.close()
                    }
                )
            )
            // Either close path (button or red-dot) records the version as
            // seen. We also revert to .accessory so Reed disappears from the
            // Dock again — same dance onboarding does on close.
            releaseOnClose(window, from: \.whatsNewWindow) {
                WhatsNew.markSeen()
                NSApp.setActivationPolicy(.accessory)
            }
            whatsNewWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        whatsNewWindow?.makeKeyAndOrderFront(nil)
    }
}
