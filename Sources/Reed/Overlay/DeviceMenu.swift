import AppKit
import SwiftUI

// Shared by MicWarningView (failed dictation — pick a replacement) and
// BluetoothNudgeView (successful dictation on a slow mic — pick a faster one).
// Split from MicWarningController.swift when the second consumer appeared.

/// Custom-styled replacement for a native `Picker`/`Menu` — SwiftUI's `Menu`
/// on macOS renders truly borderless at rest (it ignores any background or
/// border chained onto a custom label until pressed) and can append its own
/// disclosure chevron next to that label too, so styling it to match the
/// dark-glass card never landed pixel-for-pixel. Popping up a real `NSMenu`
/// from a plain `Button` sidesteps both problems: the trigger is 100% our
/// own SwiftUI content (no button-chrome fighting our styling), and the
/// transient list still gets native mouse/keyboard handling for free.
struct DeviceMenu: View {
    let devices: [AudioInputDevice]
    let currentDeviceID: String?
    /// Shown when `currentDeviceID` matches nothing in `devices`. The default
    /// suits the mic-warning toast (system default is a legitimate state
    /// there); the Bluetooth nudge overrides it with an action phrase, because
    /// its current device is deliberately not in the list and a status label
    /// would name something the menu refuses to contain.
    var placeholder: String = "System Default"
    let onSelect: (AudioInputDevice) -> Void

    @State private var isHovering = false
    @State private var anchor: NSView?
    private let target = DeviceMenuTarget()

    private var currentDevice: AudioInputDevice? {
        devices.first { $0.id == currentDeviceID }
    }

    /// Shows what's actually in use right now, not a generic placeholder —
    /// the whole point of this control is picking a replacement, so knowing
    /// the current pick matters (mirrors the Settings mic picker's own
    /// "System Default (X)" treatment).
    private var label: String {
        guard let currentDevice else { return placeholder }
        return currentDevice.isBuiltIn ? "\(currentDevice.name) (Built-in)" : currentDevice.name
    }

    var body: some View {
        Button(action: presentMenu) {
            HStack(spacing: 8) {
                Text(label)
                    .font(ReedFont.ui(12, 500))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.1 : 0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background(MenuAnchorView(view: $anchor))
    }

    @MainActor
    private func presentMenu() {
        guard let anchor else { return }
        let menu = NSMenu()
        // Forced dark to match the card, same reasoning as the panel's
        // VisualEffectView — this toast is dark-glass regardless of the
        // system's Light/Dark setting.
        menu.appearance = NSAppearance(named: .darkAqua)
        for device in devices {
            let item = NSMenuItem(
                title: device.isBuiltIn ? "\(device.name) (Built-in)" : device.name,
                action: #selector(DeviceMenuTarget.selected(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = device
            item.state = device.id == currentDeviceID ? .on : .off
            menu.addItem(item)
        }
        target.onSelect = onSelect
        menu.popUp(positioning: nil, at: .zero, in: anchor)
    }
}

/// `NSMenuItem` actions need an `NSObject` target — a plain closure can't be
/// used as a `@objc` selector target, so this small object just forwards the
/// picked device back to the SwiftUI closure.
final class DeviceMenuTarget: NSObject {
    var onSelect: ((AudioInputDevice) -> Void)?

    @objc func selected(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioInputDevice else { return }
        onSelect?(device)
    }
}

/// Captures the `NSView` backing the button so `NSMenu.popUp` has a view to
/// anchor to — the mic-warning panel is a non-activating `NSPanel`, which
/// never becomes `NSApp.keyWindow`, so that usual shortcut isn't available.
struct MenuAnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
