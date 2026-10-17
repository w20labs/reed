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
        /// When the dictation went onto the clipboard (uptime), for the
        /// diagnostic's actual elapsed time.
        let started = DispatchTime.now().uptimeNanoseconds

        init(pasteboard: NSPasteboard, saved: [[(NSPasteboard.PasteboardType, Data)]], text: String, generation: Int) {
            self.pasteboard = pasteboard
            self.saved = saved
            self.text = text
            self.generation = generation
        }
    }

    /// Bumped by every clipboard write of Reed's: a later paste or an
    /// untrusted delivery owns the clipboard, so an older paste's pending
    /// checks must not restore over it.
    private var generation = 0

    /// The latest paste while its checks are still pending. A paste that
    /// begins while the clipboard still holds this one's dictation (not yet
    /// restored, or echoed back) carries its snapshot: the clipboard then is
    /// Reed's own text, not the user's (review of PR #30).
    private var pending: Paste?

    /// Snapshots the clipboard, then puts `text` on it for the paste.
    func begin(_ text: String, on pasteboard: NSPasteboard) -> Paste {
        let saved: [[(NSPasteboard.PasteboardType, Data)]]
        if let pending, pending.pasteboard == pasteboard, pasteboard.string(forType: .string) == pending.text {
            saved = pending.saved
        } else {
            saved = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }
        generation += 1
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let paste = Paste(pasteboard: pasteboard, saved: saved, text: text, generation: generation)
        pending = paste
        return paste
    }

    /// Leaves `text` on the clipboard as the delivery itself (no
    /// Accessibility trust, so no ⌘V), and cancels every pending restore:
    /// one would erase the user's only copy of the dictation.
    func leave(_ text: String, on pasteboard: NSPasteboard) {
        generation += 1
        pending = nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The clipboard side of the paste fallback: trusted, paste and restore;
    /// untrusted, leave the dictation there. `pressPaste` posts ⌘V and
    /// `after` is the clock (the main queue in the app, a recorder in tests).
    func deliver(_ text: String, on pasteboard: NSPasteboard, trusted: Bool, pressPaste: () -> Void,
                 after: (TimeInterval, @escaping () -> Void) -> Void) {
        guard trusted else {
            leave(text, on: pasteboard)
            clog.info("AX untrusted: dictation left on the clipboard, no ⌘V")
            return
        }
        let paste = begin(text, on: pasteboard)
        pressPaste()
        scheduleRestore(paste, after: after)
    }

    /// Schedules every check of `paste`; `after` is the clock (the main
    /// queue in the app, a recorder in tests).
    func scheduleRestore(_ paste: Paste, after: (TimeInterval, @escaping () -> Void) -> Void) {
        for (index, delay) in Self.checkDelays.enumerated() {
            let last = index == Self.checkDelays.count - 1
            after(delay) { [weak self] in
                guard let self else { return }
                self.restoreIfStillOurs(paste, scheduled: delay)
                if last, self.pending === paste { self.pending = nil }
            }
        }
    }

    /// One restore check, as logged: counts, change counts and booleans,
    /// never the clipboard's contents. Tells an empty clipboard Reed found
    /// (items before 0, left) from one Reed emptied (saved 0, restored).
    enum CheckAction: String { case restored, left, superseded }

    struct Check: Equatable {
        let pasteID: Int
        let scheduledMs: Int
        let elapsedMs: Int
        let savedItems: Int
        let itemsBefore: Int
        let changeBefore: Int
        let hasText: Bool
        let textMatches: Bool
        let itemsAfter: Int
        let changeAfter: Int
        let action: CheckAction

        var line: String {
            "clipboard check paste=\(pasteID) scheduled=\(scheduledMs)ms actual=\(elapsedMs)ms saved=\(savedItems)"
                + " before=\(itemsBefore) items cc=\(changeBefore) text=\(hasText) matches=\(textMatches)"
                + " after=\(itemsAfter) items cc=\(changeAfter) action=\(action.rawValue)"
        }
    }

    /// Sees every check after it is logged (tests).
    var onCheck: ((Check) -> Void)?

    /// Restores the user's clipboard while it still holds exactly the
    /// dictation and no later paste has taken over.
    @discardableResult
    func restoreIfStillOurs(_ paste: Paste, scheduled: TimeInterval = 0) -> Check {
        let board = paste.pasteboard
        let itemsBefore = board.pasteboardItems?.count ?? 0, changeBefore = board.changeCount
        let current = board.string(forType: .string)
        let action: CheckAction
        if paste.generation != generation {
            action = .superseded
        } else if current == paste.text {
            board.clearContents()
            let items = paste.saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
            action = .restored
        } else {
            action = .left
        }
        let check = Check(
            pasteID: paste.generation, scheduledMs: Int((scheduled * 1000).rounded()),
            elapsedMs: Int((DispatchTime.now().uptimeNanoseconds - paste.started) / 1_000_000),
            savedItems: paste.saved.count, itemsBefore: itemsBefore, changeBefore: changeBefore,
            hasText: current != nil, textMatches: current == paste.text,
            itemsAfter: board.pasteboardItems?.count ?? 0, changeAfter: board.changeCount, action: action)
        clog.info(check.line)
        onCheck?(check)
        return check
    }
}
