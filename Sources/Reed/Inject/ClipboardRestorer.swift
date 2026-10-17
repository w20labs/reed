import AppKit
import Foundation

private let clog = Log(category: "inject")

/// Puts the user's clipboard back after the clipboard+⌘V paste.
///
/// The restore is decided by what the clipboard holds, not by whether it
/// changed: another program can re-write the clipboard with its own current
/// text a fraction of a second after any change (seen 2026-10-17 with
/// Terminal in front: the same text, re-written 0.18–0.41 s later). The old
/// change-count guard read that echo as a new copy and skipped the restore,
/// leaving the dictation on the clipboard and the user's copy lost. Anything
/// other than the dictation is still the user's and is never overwritten.
final class ClipboardRestorer {
    /// When the clipboard is checked after the paste. The second check
    /// catches an echo that lands after the first restore (+0.41 s seen).
    static let checkDelays: [TimeInterval] = [0.2, 1.0]

    /// One paste: the user's clipboard as it was, and the text Reed put there.
    final class Paste {
        let pasteboard: NSPasteboard
        /// Each item's data by type: an `NSPasteboardItem` can be written to
        /// a pasteboard only once, and a second restore needs fresh items.
        let saved: [[(NSPasteboard.PasteboardType, Data)]]
        let text: String
        let generation: Int
        /// Set by the first restore, so later checks finding the user's own
        /// clipboard back are not logged as a skip.
        fileprivate(set) var restored = false

        init(pasteboard: NSPasteboard, saved: [[(NSPasteboard.PasteboardType, Data)]], text: String, generation: Int) {
            self.pasteboard = pasteboard
            self.saved = saved
            self.text = text
            self.generation = generation
        }
    }

    /// Bumped by every paste: a later paste owns the clipboard, so an older
    /// paste's pending checks must not restore over it.
    private var generation = 0

    /// Snapshots the clipboard, then puts `text` on it for the paste.
    func begin(_ text: String, on pasteboard: NSPasteboard) -> Paste {
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        generation += 1
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return Paste(pasteboard: pasteboard, saved: saved, text: text, generation: generation)
    }

    /// Schedules every check of `paste`; `after` is the clock (the main
    /// queue in the app, a recorder in tests).
    func scheduleRestore(_ paste: Paste, after: (TimeInterval, @escaping () -> Void) -> Void) {
        for delay in Self.checkDelays {
            after(delay) { [weak self] in self?.restoreIfStillOurs(paste) }
        }
    }

    /// Restores the user's clipboard while it still holds exactly the
    /// dictation and no later paste has taken over. Returns whether it did.
    @discardableResult
    func restoreIfStillOurs(_ paste: Paste) -> Bool {
        guard paste.generation == generation else { return false }
        let board = paste.pasteboard
        guard board.string(forType: .string) == paste.text else {
            if !paste.restored { clog.info("clipboard holds something other than the dictation — leaving it") }
            return false
        }
        board.clearContents()
        let items = paste.saved.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
        if paste.restored { clog.info("dictation re-written to the clipboard after the restore — restored again") }
        paste.restored = true
        return true
    }
}
