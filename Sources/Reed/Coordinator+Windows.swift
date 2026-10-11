import AppKit

/// Reed's own windows (Settings, setup, What's New) are built with
/// `isReleasedWhenClosed = false` and kept in a Coordinator slot so a second
/// open reuses them. Kept after closing, a window's SwiftUI tree stays mounted
/// and its timers and repeating animations run for the rest of the session
/// (the setup window's 0.4 s readiness poll and welcome animation, the
/// shortcut field's 0.5 s poll in Settings). Releasing on close ends them; the
/// next open builds the window again, and setup resumes from its saved step.
extension Coordinator {
    /// Runs `onClose` when `window` closes, then empties `slot` (if it still
    /// holds this window) and the window's content, so nothing in it keeps
    /// running.
    func releaseOnClose(
        _ window: NSWindow,
        from slot: ReferenceWritableKeyPath<Coordinator, NSWindow?>,
        onClose: @escaping @MainActor () -> Void
    ) {
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let token { NotificationCenter.default.removeObserver(token) }
                onClose()
                if let self, self[keyPath: slot] === window { self[keyPath: slot] = nil }
                // After the close completes, not inside it.
                DispatchQueue.main.async { window.contentView = nil }
            }
        }
    }
}
