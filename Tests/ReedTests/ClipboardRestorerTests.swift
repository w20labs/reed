import AppKit
import XCTest
@testable import Reed

/// The clipboard restore after a clipboard+⌘V paste (2026-10-17): decided by
/// what the clipboard holds, so another program re-writing the dictation (an
/// echo) no longer leaves it there. Runs on a private pasteboard, never the
/// user's, and drives the production `begin` / `scheduleRestore` path with a
/// recorded clock.
final class ClipboardRestorerTests: XCTestCase {
    private var board: NSPasteboard!
    private var checks: [(TimeInterval, () -> Void)] = []

    override func setUp() {
        board = NSPasteboard(name: .init("reed-tests-\(UUID().uuidString)"))
        checks = []
    }

    override func tearDown() {
        board.releaseGlobally()
    }

    /// The user's clipboard before the dictation: rich text, as from a copy.
    private func copyUserText(_ text: String = "the user's copy") {
        board.clearContents()
        board.setString(text, forType: .string)
        board.setData(Data("<b>\(text)</b>".utf8), forType: .html)
    }

    /// Another program re-writing the clipboard's current text as plain text.
    private func echo() {
        let text = board.string(forType: .string) ?? ""
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Pastes through the production path; returns this paste's checks.
    @discardableResult
    private func paste(_ text: String, with restorer: ClipboardRestorer) -> [() -> Void] {
        let paste = restorer.begin(text, on: board)
        XCTAssertEqual(board.string(forType: .string), text)
        let first = checks.count
        restorer.scheduleRestore(paste) { delay, check in checks.append((delay, check)) }
        return checks[first...].map(\.1)
    }

    func testAnEchoOfTheDictationStillRestoresTheUsersClipboard() {
        copyUserText()
        let restorer = ClipboardRestorer()
        let pending = paste("the dictation", with: restorer)
        echo()
        pending.first?()
        XCTAssertEqual(board.string(forType: .string), "the user's copy")
        XCTAssertEqual(board.data(forType: .html), Data("<b>the user's copy</b>".utf8), "every type comes back")
    }

    func testAnEchoAfterTheFirstRestoreIsRestoredAgain() {
        copyUserText()
        let restorer = ClipboardRestorer()
        let pending = paste("the dictation", with: restorer)
        XCTAssertEqual(checks.map(\.0), ClipboardRestorer.checkDelays)
        guard pending.count >= 2 else { return XCTFail("one check cannot catch an echo after the restore") }
        pending[0]()
        // The echo of the dictation lands after the first restore (+0.41 s seen).
        board.clearContents()
        board.setString("the dictation", forType: .string)
        pending.dropFirst().forEach { $0() }
        XCTAssertEqual(board.string(forType: .string), "the user's copy")
    }

    func testANewCopyDuringThePasteIsNeverOverwritten() {
        copyUserText()
        let restorer = ClipboardRestorer()
        let pending = paste("the dictation", with: restorer)
        copyUserText("copied just now")
        pending.forEach { $0() }
        XCTAssertEqual(board.string(forType: .string), "copied just now")
    }

    func testALaterPasteOwnsTheClipboard() {
        copyUserText()
        let restorer = ClipboardRestorer()
        let older = paste("same words", with: restorer)
        older.first?()
        // A second dictation of the same words, before the first one's last check.
        let newer = paste("same words", with: restorer)
        older.dropFirst().forEach { $0() }
        XCTAssertEqual(board.string(forType: .string), "same words", "the older paste must not restore under the newer one")
        newer.first?()
        XCTAssertEqual(board.string(forType: .string), "the user's copy")
    }

    func testAnEmptyClipboardStaysEmpty() {
        board.clearContents()
        let restorer = ClipboardRestorer()
        paste("the dictation", with: restorer).forEach { $0() }
        XCTAssertNil(board.string(forType: .string))
        XCTAssertTrue(board.pasteboardItems?.isEmpty ?? true)
    }
}
