import AppKit
import Foundation

/// One dictation the menu can still hand back (P18, decided 2026-10-14).
struct RecentDictation: Identifiable, Equatable {
    let id = UUID()
    /// The text Reed wrote, after cleanup, complete: Copy returns all of it,
    /// whatever the menu's preview shows.
    let text: String
    let date: Date
    /// The app Reed targeted, captured when it attempted the insertion. The
    /// destination, not proof the paste landed: a failed paste is the case
    /// the list exists for.
    let appName: String?
}

/// The menu's recent dictations: the last five, newest first, in memory only.
/// Nothing is written to disk, so the list ends when Reed quits and the
/// privacy page's list of what Reed keeps on the Mac stays true.
struct RecentDictations: Equatable {
    static let capacity = 5
    private(set) var entries: [RecentDictation] = []

    var newest: RecentDictation? { entries.first }
    var earlier: ArraySlice<RecentDictation> { entries.dropFirst() }

    /// Text that is empty after trimming is not a dictation (Nothing to
    /// write never reaches the paste, but the guard keeps that true here).
    mutating func record(_ text: String, appName: String?, at date: Date = Date()) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(RecentDictation(text: text, date: date, appName: appName), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    mutating func clear() { entries.removeAll() }

    /// "just now", "4 min", "1 hr", "2 d" — the menu's age label.
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3600)) hr"
        default: return "\(Int(seconds / 86_400)) d"
        }
    }

    /// "4 min · Slack" in full, for accessibility and logs; the menu row
    /// truncates the app name to the width it has.
    static func label(_ entry: RecentDictation, now: Date = Date()) -> String {
        let age = age(of: entry.date, now: now)
        guard let app = entry.appName else { return age }
        return "\(age) · \(app)"
    }

    /// The display name of the app with `bundleID`: the running copy's name,
    /// else the installed bundle's, else nothing (the label shows time only).
    static func appName(forBundleID bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
