import AppKit
import SwiftUI
import XCTest
@testable import Reed

@MainActor
/// Review of PR #28 (2026-10-14), kept as the exit tests: a long app name
/// must not crowd out the preview, and each Copy shows "Copied" for its own
/// 1.6 s, however recently that entry (or another) was copied.
final class RecentDictationsUIReviewTests: XCTestCase {
    private func makeCard(app: String?, ready: ((RecentDictationsCard) -> Void)? = nil, width: ((CGFloat) -> Void)? = nil) async -> (NSWindow, NSHostingView<RecentDictationsCard>) {
        _ = NSApplication.shared
        var recent = RecentDictations()
        recent.record("This is the older dictation I need to recover", appName: app)
        recent.record("The latest dictation", appName: "Notes")
        let host = NSHostingView(rootView: RecentDictationsCard(dictations: recent, onClear: {}, rowWidthForTesting: width, copyReadyForTesting: ready))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 264, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(NSSize(width: 264, height: 320))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 400_000_000)
        return (window, host)
    }

    func testNativeCardLayoutWithLongAppName() async throws {
        var previewWidth: CGFloat?
        let (window, host) = await makeCard(app: "Visual Studio Code - Insiders", width: { previewWidth = $0 })
        defer { window.close() }
        let measured = try XCTUnwrap(previewWidth)
        XCTAssertGreaterThanOrEqual(measured, 60, "The preview must retain useful space when an app has an ordinary long name (host \(host.bounds.width) pt)")
    }

    func testRepeatingCopyGetsANewFeedbackInterval() async throws {
        try await checkFeedback(first: 0, second: 0)
    }

    func testCopyingADifferentEntryKeepsItsFeedback() async throws {
        try await checkFeedback(first: 0, second: 1)
    }

    func testRepeatingEarlierCopyGetsANewFeedbackInterval() async throws {
        try await checkFeedback(first: 1, second: 1)
    }

    func testCopyingAnotherEntryThenReturningGetsANewFeedbackInterval() async throws {
        try await checkFeedback(first: 0, second: 0, copyOtherInBetween: true)
    }

    private func checkFeedback(first: Int, second: Int, copyOtherInBetween: Bool = false) async throws {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { original in
            let item = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { item.setData(data, forType: type) }
            }
            return item
        }
        defer {
            if ["The latest dictation", "This is the older dictation I need to recover"].contains(pasteboard.string(forType: .string) ?? "") {
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        var liveCard: RecentDictationsCard?
        let (window, _) = await makeCard(app: "Slack", ready: { liveCard = $0 })
        defer { window.close() }
        let card = try XCTUnwrap(liveCard)
        let entry = card.dictations.entries[first]
        card.copy(entry)
        XCTAssertEqual(card.copiedID, entry.id)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        if copyOtherInBetween { card.copy(card.dictations.entries[1]) }
        let repeated = card.dictations.entries[second]
        card.copy(repeated)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(card.copiedID, repeated.id, "A repeated copy must still show Copied until 1.6 s after that click")
    }
}
