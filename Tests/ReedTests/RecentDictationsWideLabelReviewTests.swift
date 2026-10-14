import AppKit
import SwiftUI
import XCTest
@testable import Reed

@MainActor
/// Second review of PR #28 (2026-10-14), kept as the exit tests: a label
/// bounded by characters is not bounded in width. CJK names and wide glyphs
/// must still leave the preview useful room, and the newest entry's Copy
/// button its full width.
final class RecentDictationsWideLabelReviewTests: XCTestCase {
    private func check(_ appName: String, newest: Bool = false) async throws {
        _ = NSApplication.shared
        var recent = RecentDictations()
        recent.record("This is the older dictation I need to recover", appName: appName)
        recent.record("The latest dictation", appName: newest ? appName : "Notes")
        var previewWidth: CGFloat?
        let card = RecentDictationsCard(dictations: recent, onClear: {}, rowWidthForTesting: { previewWidth = $0 })
        let host = NSHostingView(rootView: card)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 264, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(NSSize(width: 264, height: 320))
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        let measured = try XCTUnwrap(previewWidth)
        let entry = try XCTUnwrap(recent.earlier.first)
        XCTAssertGreaterThanOrEqual(measured, 60, "The preview must retain useful space for localized app names and wide glyphs")
    }

    /// Sibling in the newest entry's header: the label must not squeeze Copy.
    func testAWideLabelDoesNotSqueezeTheNewestCopyButton() async throws {
        func copyWidth(app: String) async throws -> CGFloat {
            _ = NSApplication.shared
            var recent = RecentDictations()
            recent.record("The latest dictation", appName: app)
            var width: CGFloat?
            let host = NSHostingView(rootView: RecentDictationsCard(dictations: recent, onClear: {}, copyButtonWidthForTesting: { width = $0 }))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 264, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setContentSize(NSSize(width: 264, height: 200))
            window.orderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 400_000_000)
            return try XCTUnwrap(width)
        }
        let natural = try await copyWidth(app: "Notes")
        let squeezed = try await copyWidth(app: "阿里云企业协同办公平台桌面客户端")
        XCTAssertEqual(squeezed, natural, accuracy: 0.5, "a wide app name squeezed the Copy button")
    }

    func testSixteenCJKCharactersLeaveAUsefulPreview() async throws {
        try await check("腾讯会议教育版（企业专用客户端）")
    }

    func testSixteenWideLatinCharactersLeaveAUsefulPreview() async throws {
        try await check(String(repeating: "W", count: 16))
    }

    func testWideLabelsInBothNewestAndEarlierEntriesKeepAUsefulPreview() async throws {
        try await check("阿里云企业协同办公平台桌面客户端", newest: true)
    }
}
