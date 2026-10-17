import AppKit
import XCTest
@testable import Reed

final class ClipboardRestorerReviewTests: XCTestCase {
    private func checkRapidSecondPaste(first: String, second: String) {
        let board = NSPasteboard(name: .init("reed-review-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original copy", forType: .string)

        let restorer = ClipboardRestorer()
        let older = restorer.begin(first, on: board)
        var oldChecks: [() -> Void] = []
        restorer.scheduleRestore(older) { _, check in oldChecks.append(check) }

        // The next dictation finishes before the first 0.2 s restore.
        let newer = restorer.begin(second, on: board)
        var newChecks: [() -> Void] = []
        restorer.scheduleRestore(newer) { _, check in newChecks.append(check) }
        oldChecks.forEach { $0() }
        newChecks.forEach { $0() }

        XCTAssertEqual(board.string(forType: .string), "original copy")
    }

    func testDifferentSecondPasteBeforeFirstRestoreKeepsOriginalCopy() {
        checkRapidSecondPaste(first: "first dictation", second: "second dictation")
    }

    func testSameSecondPasteBeforeFirstRestoreKeepsOriginalCopy() {
        checkRapidSecondPaste(first: "same dictation", second: "same dictation")
    }

    func testSecondPasteAfterAnEchoKeepsOriginalCopy() {
        let board = NSPasteboard(name: .init("reed-review-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original copy", forType: .string)

        let restorer = ClipboardRestorer()
        let older = restorer.begin("first dictation", on: board)
        var oldChecks: [() -> Void] = []
        restorer.scheduleRestore(older) { _, check in oldChecks.append(check) }
        oldChecks[0]() // The 0.2 s check restored the original.

        // The observed external echo lands after that check, before 1 s.
        board.clearContents()
        board.setString("first dictation", forType: .string)
        let newer = restorer.begin("second dictation", on: board)
        var newChecks: [() -> Void] = []
        restorer.scheduleRestore(newer) { _, check in newChecks.append(check) }
        oldChecks.dropFirst().forEach { $0() }
        newChecks.forEach { $0() }

        XCTAssertEqual(board.string(forType: .string), "original copy")
    }

    func testUntrustedDeliverySupersedesPendingRestore() {
        let board = NSPasteboard(name: .init("reed-review-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original copy", forType: .string)

        let restorer = ClipboardRestorer()
        let trusted = restorer.begin("dictation", on: board)
        var checks: [() -> Void] = []
        restorer.scheduleRestore(trusted) { _, check in checks.append(check) }

        // TextInjector's untrusted path, through the production seam: the
        // same dictation left on the clipboard as the only delivery.
        restorer.deliver("dictation", on: board, trusted: false, pressPaste: { XCTFail("no ⌘V untrusted") }) { _, _ in
            XCTFail("an untrusted delivery schedules no restore")
        }
        checks.forEach { $0() }
        XCTAssertEqual(board.string(forType: .string), "dictation")
    }
}
