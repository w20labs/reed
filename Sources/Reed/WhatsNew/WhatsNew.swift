import Foundation

/// One feature highlight on the What's New sheet — an SF Symbol, a tight
/// label, and one line of explanation. The icon stays monochrome
/// (Charcoal · Soft Tonal); copy is the variable that carries meaning.
struct WhatsNewItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let body: String
}

/// Per-version highlight content. When a user launches Reed and the running
/// `CFBundleShortVersionString` doesn't match `lastSeenVersion`, the entry
/// for the running version (if any) is shown once and then marked seen.
///
/// To advertise a new feature: bump the app version, then add an entry to
/// `entries[newVersion]` below. No entry = no sheet for that version (use
/// this for bugfix releases that don't need a callout).
struct WhatsNewEntry {
    let version: String
    let tagline: String      // small all-caps eyebrow ("NEW IN REED 0.1.20")
    let title: String        // big headline
    let intro: String        // one-paragraph framing
    let items: [WhatsNewItem]
    let footnote: String?    // optional small line beneath items
}

enum WhatsNew {
    /// Where we record which version's sheet has been shown. Nil (never set)
    /// means the user has never seen any What's New — typically a pre-this-
    /// system upgrade. Onboarding writes this on completion so fresh installs
    /// don't see both onboarding *and* a sheet on their first launch.
    static let lastSeenVersionKey = "reed.whatsNew.lastSeenVersion"

    /// The version this binary identifies as. Empty in unit tests / SPM
    /// builds without an Info.plist — in that case `current()` returns nil
    /// and the sheet never fires, which is the safe default.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// The entry to show on this launch, if any. nil when:
    /// - the running version has no registered entry (bugfix release), or
    /// - the user has already seen the entry for this version.
    static func pending() -> WhatsNewEntry? {
        let version = currentVersion
        guard !version.isEmpty, let entry = entries[version] else { return nil }
        let lastSeen = UserDefaults.standard.string(forKey: lastSeenVersionKey)
        return lastSeen == version ? nil : entry
    }

    /// Stamp the current version as seen. Idempotent — safe to call from the
    /// sheet's close handler or onboarding's completion handler.
    static func markSeen() {
        guard !currentVersion.isEmpty else { return }
        UserDefaults.standard.set(currentVersion, forKey: lastSeenVersionKey)
    }

    /// Registry of per-version highlights. Keep this list short: only ship
    /// an entry for releases that introduce something a user couldn't infer
    /// from the menubar or Settings on their own.
    /// Empty since 2026-09-15: the only entry advertised formatting modes,
    /// which were removed with the paid features.
    static let entries: [String: WhatsNewEntry] = [:]
}
