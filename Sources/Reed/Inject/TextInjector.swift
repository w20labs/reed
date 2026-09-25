import AppKit
import ApplicationServices
import Foundation

private let ilog = Log(category: "inject")

final class TextInjector {
    /// How the last `inject` landed — appended to the persisted per-dictation
    /// forensics line, because "I talked and it disappeared" was undiagnosable:
    /// the pipeline proved text was produced and handed to injection, but
    /// nothing recorded WHERE it went or which path (AX vs clipboard) took it.
    /// Numbers + bundle ID only, never content.
    private(set) var lastReport = ""

    /// What one `inject` actually did: the sanitized string that reached the
    /// destination, the destination, and the path (review 2026-09-04, P2:
    /// the review copy used to record the pre-sanitize input and re-query
    /// the frontmost app afterwards).
    struct Receipt: Equatable {
        let text: String
        let target: String?
        let method: String
    }

    /// The receipt of the last `inject`.
    private(set) var lastReceipt: Receipt?

    @discardableResult
    func inject(_ text: String) -> Receipt {
        // The injected string is on-device-model-controlled, so it's
        // untrusted: sanitize control characters before it's typed or
        // pasted (see `sanitize`). One choke point covers both the AX and the
        // clipboard+⌘V paths.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let text = Self.sanitize(text, forTarget: bundleID)
        let axTrusted = AXIsProcessTrusted()
        ilog.info("inject(\(text.count) chars); AXIsProcessTrusted=\(axTrusted); frontmost=\(bundleID ?? "<nil>")")

        let target = bundleID ?? "unknown"
        if tryAXInsert(text) {
            ilog.info("AX path succeeded")
            lastReport = "inject ax \(text.count)ch → \(target)"
            lastReceipt = Receipt(text: text, target: bundleID, method: "ax")
            return lastReceipt!
        }
        ilog.info("AX path failed; falling back to clipboard+⌘V")
        pasteViaClipboard(text)
        lastReport = "inject paste \(text.count)ch → \(target)\(axTrusted ? "" : " (AX untrusted)")"
        lastReceipt = Receipt(text: text, target: bundleID, method: axTrusted ? "paste" : "paste-untrusted")
        return lastReceipt!
    }

    /// Strips control characters that are dangerous when the clipboard+⌘V
    /// fallback lands in a terminal (PR #53 made that path reach terminals):
    /// an ESC begins an escape sequence (cursor control, OSC 52 clipboard
    /// writes), a carriage return or trailing newline submits the line at a
    /// shell prompt. Keep the only two C0 controls that are legitimate in
    /// dictated output — newline and tab — drop every other C0 control
    /// (including ESC and CR) plus DEL and the C1 range (U+0080–U+009F, where
    /// U+009B is a single-byte CSI), and trim trailing newlines so a paste
    /// never auto-executes. Interior newlines are real content (multi-line
    /// emails, lists) and are preserved — EXCEPT when the target is a
    /// terminal (2026-08-25 finding): "safe command\nsecond command" submits
    /// the first line in any shell/REPL without multiline-paste protection
    /// (bash 3.2 — macOS's own — has none), and an interior tab triggers
    /// completion. Dictation into a terminal is never intentionally
    /// multi-line, so there every \n and \t flattens to a space. Pure +
    /// static so it's unit-testable without AX/pasteboard.
    static func sanitize(_ text: String, forTarget bundleID: String? = nil) -> String {
        let flattenForTerminal = AppCategory.category(for: bundleID) == "terminal"
        var cleaned = String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x0A, 0x09: return true                    // keep \n and \t
            case 0x00...0x1F, 0x7F...0x9F: return false     // drop other C0 controls + DEL + C1 (ESC, CR, NUL, BEL, CSI…)
            default: return true
            }
        }))
        while cleaned.hasSuffix("\n") { cleaned.removeLast() }
        if flattenForTerminal {
            cleaned = cleaned
                .replacingOccurrences(of: "[\\n\\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return cleaned
    }

    private func tryAXInsert(_ text: String) -> Bool {
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let getErr = AXUIElementCopyAttributeValue(
            sys,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard getErr == .success, let focused = focusedRef else {
            ilog.info("AX insert: no focused element (err=\(getErr.rawValue))")
            return false
        }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            ilog.info("AX insert: focused ref is not an AXUIElement")
            return false
        }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement

        // Guard that the element actually accepts writes — some apps (e.g. Terminal)
        // return .success from AXUIElementSetAttributeValue without inserting anything.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else {
            ilog.info("AX insert: selected-text attribute not settable on focused element")
            return false
        }

        // If the selection can't be read BEFORE the write, verification is
        // impossible — bail to the paste path now rather than writing first
        // and then double-injecting on the unverifiable result (finding
        // 2026-08-25).
        guard let oldRange = selectionRange(of: element) else {
            ilog.info("AX insert: selection unreadable pre-write — using paste path")
            return false
        }

        // Setting kAXSelectedTextAttribute inserts at caret if selection is empty,
        // or replaces the selection otherwise. Many native fields support this.
        let setErr = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard setErr == .success else {
            ilog.info("AX insert: set failed (err=\(setErr.rawValue))")
            return false
        }

        // Some apps (Chromium/Electron editors, e.g. Cursor) return .success above
        // without actually inserting anything. Confirm the caret genuinely moved
        // past the inserted text — via the selection range, not the field's full
        // value, so this stays cheap regardless of document size.
        guard let new = selectionRange(of: element) else {
            // The write REPORTED success and the field was verified settable;
            // an unreadable post-write selection is a verification gap, not
            // evidence of failure. Falling back here pasted the text a second
            // time (finding 2026-08-25) — accept.
            ilog.info("AX insert: write ok but selection unreadable post-write — accepting")
            return true
        }
        let old = oldRange
        let insertedLength = text.utf16.count
        let landed = new.location >= old.location
            && new.location + new.length >= old.location + insertedLength
        if !landed {
            ilog.info("AX insert: set reported success but caret didn't move (old=\(old.location)+\(old.length) new=\(new.location)+\(new.length) needed +\(insertedLength)) — treating as failed")
        }
        return landed
    }

    /// Reads the focused element's caret/selection as a CFRange (UTF-16 offsets),
    /// or nil if unavailable.
    private func selectionRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard err == .success, let value = rangeRef, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func pasteViaClipboard(_ text: String) {
        let pb = NSPasteboard.general

        // Untrusted: macOS will discard the synthesized ⌘V, so the clipboard
        // is the delivery, not a vehicle — set it and never restore over it
        // (the restore would erase the user's only copy of the dictation).
        guard AXIsProcessTrusted() else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            ilog.info("AX untrusted: dictation left on the clipboard, no ⌘V")
            return
        }

        // Snapshot existing pasteboard so we can restore it after our paste.
        let savedItems: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChangeCount = pb.changeCount

        synthesizeCommandV()

        // Restore the original clipboard after the paste lands — but ONLY if
        // the pasteboard still holds our paste. If the user (or any app)
        // copied something in the window, restoring would overwrite their
        // new clipboard with the stale snapshot (finding 2026-08-25).
        let restoreAfter: TimeInterval = 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreAfter) {
            guard pb.changeCount == ourChangeCount else {
                ilog.info("clipboard changed during paste window — skipping snapshot restore")
                return
            }
            pb.clearContents()
            if !savedItems.isEmpty {
                pb.writeObjects(savedItems)
            }
        }
    }

    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09 // V

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            ilog.error("CGEvent creation failed")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        ilog.info("posted ⌘V CGEvents")
    }

    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
