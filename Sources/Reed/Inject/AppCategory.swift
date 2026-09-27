import Foundation

/// Maps a frontmost-app bundle ID to a small fixed taxonomy. Used by the
/// injector's terminal check (`TextInjector.sanitize`).
enum AppCategory {
    private static let byBundleID: [String: String] = [
        // terminal
        "com.apple.Terminal": "terminal",
        "com.googlecode.iterm2": "terminal",
        "dev.warp.Warp-Stable": "terminal",
        "org.alacritty": "terminal",
        "com.mitchellh.ghostty": "terminal",
        "net.kovidgoyal.kitty": "terminal",
        "org.tabby": "terminal",
        "com.github.wez.wezterm": "terminal",
        "co.zeit.hyper": "terminal",
        // ide
        "com.apple.dt.Xcode": "ide",
        "com.microsoft.VSCode": "ide",
        "com.todesktop.230313mzl4w4u92": "ide", // Cursor
        "com.jetbrains.intellij": "ide",
        "com.jetbrains.pycharm": "ide",
        "com.jetbrains.WebStorm": "ide",
        "dev.zed.Zed": "ide",
        "com.sublimetext.4": "ide",
        // chat
        "com.tinyspeck.slackmacgap": "chat",
        "com.hnc.Discord": "chat",
        "com.apple.MobileSMS": "chat",
        "com.microsoft.teams2": "chat",
        "net.whatsapp.WhatsApp": "chat",
        "org.telegram.desktop": "chat",
        // email
        "com.apple.mail": "email",
        "com.microsoft.Outlook": "email",
        "com.readdle.smartemail-Mac": "email", // Spark
        "com.airmailapp.airmail2": "email",
        // browser
        "com.apple.Safari": "browser",
        "com.google.Chrome": "browser",
        "company.thebrowser.Browser": "browser", // Arc
        "org.mozilla.firefox": "browser",
        "com.microsoft.edgemac": "browser",
        "com.brave.Browser": "browser",
        // notes_docs
        "com.apple.Notes": "notes_docs",
        "notion.id": "notes_docs",
        "md.obsidian": "notes_docs",
        "com.microsoft.Word": "notes_docs",
        "com.apple.iWork.Pages": "notes_docs",
    ]

    /// Bucket a frontmost-app bundle ID into the fixed taxonomy. `nil` (no
    /// frontmost app read) is distinct from a real-but-unmapped bundle ID:
    /// `"unknown"` vs `"other"` — only the latter names an app to add.
    static func category(for bundleID: String?) -> String {
        guard let bundleID else { return "unknown" }
        return byBundleID[bundleID] ?? "other"
    }
}
