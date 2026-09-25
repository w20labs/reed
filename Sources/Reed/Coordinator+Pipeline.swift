import AppKit
import ApplicationServices
import Foundation

/// How a dictation settles once its pipeline reaches the end. Split out of
/// Coordinator.swift to keep the class body under swiftlint's
/// `type_body_length` warning (300).
extension Coordinator {
    /// Post-inject check: with Accessibility untrusted the paste never landed,
    /// whatever the pipeline did. Surfaces the actionable error instead of
    /// letting the flow settle to Done. Returns true when the error was raised.
    func surfaceInjectionFailureIfNeeded() -> Bool {
        guard !AXIsProcessTrusted() else { return false }
        let err = DictationError.accessibilityUntrusted
        activeError = err
        state = .error(err.headline)
        return true
    }

    /// Settles a dictation that reached the end of its pipeline: surface an
    /// injection failure if there was one, otherwise go idle. The proactive
    /// Bluetooth nudge is considered only on the clean path, so it can never
    /// land on top of an error the user is already reading.
    func finishDictation() {
        endReview()
        if surfaceInjectionFailureIfNeeded() { return }
        state = .idle
        maybeNudgeAboutBluetooth()
    }
}
