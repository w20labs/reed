import AppKit
import SwiftUI

/// A one-shot floating toast (à la Slack's "Is your microphone muted?") shown
/// when a Bluetooth mic never confirmed real signal before the user released
/// the hotkey — the SCO handshake most likely ate the whole dictation.
/// Deliberately separate from OverlayController's top-center HUD (that
/// mirrors in-progress dictation state, not a one-off warning) — this needs
/// to be seen right when it's relevant, so it floats over whatever the user
/// is doing rather than waiting for them to open the menu.
@MainActor
final class MicWarningController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(
        headline: String,
        detail: String,
        devices: [AudioInputDevice],
        currentDeviceID: String?,
        onSelect: @escaping (AudioInputDevice) -> Void
    ) {
        log.info("MicWarningController.show: \(devices.count) candidate device(s)")
        present(MicWarningView(
            headline: headline,
            detail: detail,
            devices: devices,
            currentDeviceID: currentDeviceID,
            onSelect: { [weak self] device in
                log.info("MicWarningController: user picked \(device.name)")
                onSelect(device)
                self?.hide()
            },
            onDismiss: { [weak self] in
                log.info("MicWarningController: dismissed")
                self?.hide()
            }
        ))
    }

    /// The proactive nudge (see `BluetoothNudgeView`). Shares this controller's
    /// panel because the two are mutually exclusive by construction — the
    /// warning follows a failed dictation, the nudge a successful one — so
    /// there is no case where both want the screen at once.
    func showBluetoothNudge(devices: [AudioInputDevice],
                            onSelect: @escaping (AudioInputDevice) -> Void,
                            onOpenSettings: @escaping () -> Void,
                            onNeverAgain: @escaping () -> Void) {
        log.info("MicWarningController: showing proactive Bluetooth nudge (\(devices.count) pinnable)")
        present(BluetoothNudgeView(
            devices: devices,
            onSelect: { [weak self] device in
                log.info("Bluetooth nudge: user switched to \(device.name)")
                onSelect(device)
                self?.hide()
            },
            onOpenSettings: { [weak self] in
                log.info("Bluetooth nudge: opening Sound Settings")
                onOpenSettings()
                self?.hide()
            },
            onNeverAgain: { [weak self] in
                log.info("Bluetooth nudge: suppressed permanently by user")
                onNeverAgain()
                self?.hide()
            },
            onDismiss: { [weak self] in self?.hide() }
        ))
    }

    private func present(_ content: some View, autoDismissAfter seconds: UInt64 = 8) {
        // No running NSApplication means no session to present into — a unit
        // test, or a headless CI runner. There is nobody to see the toast, and
        // headless UI muddies hang diagnostics (see OverlayController.show();
        // the CI hang this was once blamed for was actually Sparkle's modal —
        // see Updater.init).
        guard NSApplication.shared.isRunning else {
            log.info("no running NSApplication — skipping toast presentation")
            return
        }
        hideTask?.cancel()
        if panel == nil { buildPanel() }
        guard let panel else {
            log.error("MicWarningController.present: panel is nil after buildPanel()")
            return
        }

        let hosting = NSHostingView(rootView: content)
        // Size the panel to the SwiftUI content's natural size (fixed width,
        // auto height) rather than guessing — avoids clipping if the detail
        // text wraps to an extra line.
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        reposition()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }

        // Auto-dismiss so a missed toast doesn't linger forever, but long
        // enough to read and act on.
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if Task.isCancelled { return }
            log.info("MicWarningController: auto-dismissing after timeout")
            await MainActor.run { self?.hide() }
        }
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak panel] in
                if let panel, panel.alphaValue < 0.05 { panel.orderOut(nil) }
            }
        )
    }

    private func buildPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false   // shadow is rendered inside SwiftUI
        p.ignoresMouseEvents = false   // buttons need to be clickable
        p.hidesOnDeactivate = false
        p.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel = p
    }

    /// Centered horizontally, in the lower third of whichever screen has the
    /// mouse cursor — deliberately not top-center, so it reads as a distinct
    /// "something needs your attention" toast rather than part of the
    /// dictation-progress HUD.
    private func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
        guard let screen else { return }

        let frame = screen.frame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + frame.height * 0.22
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The toast's content: warning icon + headline + detail, and a dropdown to
/// pick a replacement mic plus a close button. Dark card regardless of
/// system appearance — it floats over arbitrary app content, same reasoning
/// as Slack/Discord's equivalent toast.
private struct MicWarningView: View {
    let headline: String
    let detail: String
    let devices: [AudioInputDevice]
    let currentDeviceID: String?
    let onSelect: (AudioInputDevice) -> Void
    let onDismiss: () -> Void

    private var pickableDevices: [AudioInputDevice] {
        devices.sorted { $0.isBuiltIn && !$1.isBuiltIn }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Same amber "!" badge as the HUD's actionable error state — this
            // toast and the HUD should read as one visual language.
            HUDCardHeader(headline: headline, detail: detail, onDismiss: onDismiss)

            DeviceMenu(devices: pickableDevices, currentDeviceID: currentDeviceID, onSelect: onSelect)
        }
        .hudCard()
    }
}
