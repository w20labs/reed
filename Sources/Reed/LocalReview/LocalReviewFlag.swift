import Foundation

/// Developer-only local review (P16, DECIDED 2026-09-04): while this key is
/// present the app keeps a text-only copy of each dictation — what was
/// heard, what the model proposed, what the gate decided, what was typed —
/// under `LocalReviewStore.directory`, for 14 days, for the QA page to
/// review — and, since 2026-09-06, the recording as a WAV beside it, so the
/// corpus bench can replay real speech through the whole pipeline. The
/// shipped app has no control and no string for it; a developer
/// opts in explicitly with `scripts/qa/review.sh on` (and out with `off`):
///
///   defaults write com.local.reed reed.localReview -bool YES
///
/// The QA launcher never writes it. A customer's Mac never runs the tooling,
/// so never has the key, so never writes a copy. The content-free counts (`CleanupCounts`) are computed
/// on every Mac regardless and ride the timings line and, under the
/// analytics consent, the dictation event.
enum LocalReviewFlag {
    static let key = "reed.localReview"

    static var isEnabled: Bool { isEnabled(in: .standard) }

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// Versions stamped into every copy so records stay comparable across
/// builds. Bump when the thing they name changes.
enum LocalReviewVersions {
    /// The record's own shape. 2 (2026-09-05): segments carry audio/asr ms
    /// and a span replaces the segment index on chunks; attempts carry a
    /// verdict; the injected string and target are recorded. 3 (2026-09-06):
    /// the `restartCollapsed` seam decision and its count. 4 (2026-09-06):
    /// `audioFile`, the recording beside the copy. 5 (2026-09-07): seam
    /// verdicts (`seamPeriod`/`seamComma`/`seamNothing`) and their count
    /// (`seamsRuled`). 6 (2026-09-10): segments carry their PCM byte
    /// range (`pcmStart`/`pcmEnd`), the live seal points, and `delivered`,
    /// the cleaned text assembly received.
    static let schema = 6
    /// The cleanup prompt (AICleanup: "v5", 2026-09-06 — the bounded restart rule).
    static let prompt = "v5"
    /// The gate's licence set (round 3, 2026-09-06: the shared restart licence).
    static let gate = "2026-09-06-r3"

    static var app: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
