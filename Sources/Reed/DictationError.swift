import Foundation

/// A user-facing dictation failure: curated human copy + where to fix it,
/// derived from the raw recorder error. The pill shows `headline`; the menu
/// shows `headline` + `detail` + an action + the collapsible `raw` (which also
/// feeds Sentry). Never surface `error.localizedDescription` directly — it
/// leaks raw error text into a 260 pt pill.
struct DictationError: Equatable {
    enum Action: Equatable { case none, openSettings, openPermissions }
    enum Severity: Equatable { case actionable, hard }

    let headline: String
    let detail: String
    let action: Action
    let raw: String
    let severity: Severity

    var actionTitle: String? {
        switch action {
        case .none: return nil
        case .openSettings: return "Open Settings"
        case .openPermissions: return "Open Settings"
        }
    }

    /// Injection with Accessibility untrusted: macOS silently discards the
    /// ⌘V events, so the dictation lands on the clipboard and nowhere else —
    /// the one injection failure detectable deterministically. Never let it
    /// read as Done.
    static var accessibilityUntrusted: DictationError {
        .init(headline: "Couldn't paste - Accessibility needed",
              detail: "Your words are on the clipboard - press ⌘V to paste them. "
                + "Grant Accessibility in Settings → Permissions and Reed pastes automatically.",
              action: .openPermissions, raw: "AXIsProcessTrusted() == false", severity: .actionable)
    }

    /// Map a thrown error to curated copy.
    static func classify(_ error: Error) -> DictationError {
        let raw = error.localizedDescription

        if let rec = error as? AudioRecorder.RecorderError {
            switch rec {
            case .micDenied:
                return .init(headline: "Microphone access off",
                             detail: "Reed can't hear you. Grant microphone access in System Settings › Privacy.",
                             action: .openPermissions, raw: raw, severity: .actionable)
            case .deviceFormatMismatch:
                return .init(headline: "Can't use that microphone",
                             detail: "Reed couldn't start your selected microphone. "
                                   + "Pick a different one in Settings › Dictation, "
                                   + "or set it as your Mac's input in Sound settings.",
                             action: .openSettings, raw: raw, severity: .actionable)
            case .noInput:
                return .init(headline: "No microphone found",
                             detail: "No audio input device is available. Connect a mic and try again.",
                             action: .none, raw: raw, severity: .actionable)
            case .converterFailed:
                return .init(headline: "Audio setup failed",
                             detail: "Reed couldn't start the audio converter. Try again.",
                             action: .none, raw: raw, severity: .hard)
            }
        }

        return .init(headline: "Something went wrong",
                     detail: "Your dictation couldn't be completed. Try again.",
                     action: .none, raw: raw, severity: .hard)
    }

    /// Fallback used at the error sites that don't carry a typed error.
    static func generic(headline: String, detail: String, raw: String,
                        action: Action = .none) -> DictationError {
        .init(headline: headline, detail: detail, action: action, raw: raw, severity: .actionable)
    }
}
