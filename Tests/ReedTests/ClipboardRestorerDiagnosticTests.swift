import AppKit
import XCTest
@testable import Reed

/// The per-check diagnostic (review of PR #30): it must tell an empty
/// clipboard Reed found from one Reed emptied, and never log contents.
/// Private pasteboard, production `deliver` path, recorded clock.
final class ClipboardRestorerDiagnosticTests: XCTestCase {
    private var board: NSPasteboard!
    private var checks: [Check] = []
    private var pending: [() -> Void] = []
    private let restorer = ClipboardRestorer()
    private typealias Check = ClipboardRestorer.Check

    override func setUp() {
        board = NSPasteboard(name: .init("reed-tests-\(UUID().uuidString)"))
        board.clearContents()
        restorer.onCheck = { [unowned self] in checks.append($0) }
    }

    override func tearDown() { board.releaseGlobally() }

    private func paste(_ text: String) {
        restorer.deliver(text, on: board, trusted: true, pressPaste: {}) { delay, check in
            pending.append { check() }
            XCTAssertTrue(ClipboardRestorer.checkDelays.contains(delay))
        }
    }

    func testAnEmptyClipboardReedFoundIsLeftAndSaysSo() throws {
        board.setString("secret original", forType: .string)
        paste("secret dictation")
        board.clearContents() // another program empties it before the check
        pending[0]()
        let check = try XCTUnwrap(checks.first)
        XCTAssertEqual(check.action, .left)
        XCTAssertEqual(check.savedItems, 1)
        XCTAssertEqual(check.itemsBefore, 0)
        XCTAssertFalse(check.hasText)
        XCTAssertFalse(check.textMatches)
        XCTAssertEqual(check.changeAfter, check.changeBefore, "Reed did not touch it")
        XCTAssertEqual(check.scheduledMs, 200)
        XCTAssertGreaterThanOrEqual(check.elapsedMs, 0)
    }

    func testAnEmptyClipboardReedRestoredIsReportedAsReeds() throws {
        paste("secret dictation") // the user's clipboard was empty
        pending[0]()
        let check = try XCTUnwrap(checks.first)
        XCTAssertEqual(check.action, .restored)
        XCTAssertEqual(check.savedItems, 0)
        XCTAssertEqual(check.itemsBefore, 1)
        XCTAssertTrue(check.textMatches)
        XCTAssertEqual(check.itemsAfter, 0)
        XCTAssertGreaterThan(check.changeAfter, check.changeBefore, "Reed cleared it")
    }

    func testEveryCheckIsLoggedWithItsScheduleAndPasteID() {
        board.setString("secret original", forType: .string)
        paste("secret dictation")
        paste("secret dictation two")
        pending.forEach { $0() }
        XCTAssertEqual(checks.map(\.scheduledMs), [200, 1000, 200, 1000])
        XCTAssertEqual(checks.map(\.action), [.superseded, .superseded, .restored, .left])
        XCTAssertEqual(Set(checks.map(\.pasteID)).count, 2)
        XCTAssertEqual(board.string(forType: .string), "secret original")
    }

    func testTheLogLineCarriesNoContents() {
        board.setString("secret original", forType: .string)
        board.setData(Data("<b>secret html</b>".utf8), forType: .html)
        paste("secret dictation")
        pending.forEach { $0() }
        XCTAssertFalse(checks.isEmpty)
        for check in checks {
            XCTAssertFalse(check.line.contains("secret"), check.line)
            XCTAssertTrue(check.line.contains("action=\(check.action.rawValue)"))
        }
    }
}
