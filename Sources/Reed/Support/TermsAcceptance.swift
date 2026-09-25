import Foundation

/// Records the user's acceptance of the Terms of Service + Privacy Policy
/// (design P12, 2026-08-07). The affirmative act is the Welcome step's
/// Continue — or, for anyone who dismissed onboarding and set Reed up
/// manually through Settings, starting the model download: the one gate every
/// working free-tier install crosses (no model, no dictation — enforced by
/// the pipeline, not policy). Both surfaces show the same conspicuous
/// footnote next to the action.
enum TermsAcceptance {
    /// Bump when the published terms change materially — a stored mismatch is
    /// the re-acceptance hook.
    nonisolated static let currentVersion = "2026-08-07"
    nonisolated static let versionKey = "reed.terms.acceptedVersion"
    nonisolated static let dateKey = "reed.terms.acceptedAt"

    nonisolated static var isRecorded: Bool {
        UserDefaults.standard.string(forKey: versionKey) == currentVersion
    }

    /// Idempotent; stamps version + ISO-8601 acceptance time.
    nonisolated static func record() {
        guard !isRecorded else { return }
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
        UserDefaults.standard.set(
            ISO8601DateFormatter().string(from: Date()), forKey: dateKey)
    }
}
