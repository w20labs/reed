import XCTest
@testable import Reed

/// The acknowledgements reader must show what the app actually packages, and
/// say so plainly when it cannot. Every case builds its own resource tree in a
/// temp directory — no real bundle or checkout is read or modified, and the
/// expected inventory is written by the test, never taken from the loader.
final class AcknowledgementsStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.root) }
    }

    // MARK: - Fixtures

    private func write(_ relative: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A tree with one notice plus every per-asset text the app ships.
    private func writeCompleteTree() throws {
        try write("ThirdPartyLicenses/Sparkle-LICENSE.txt", "Sparkle licence text\n")
        for asset in AcknowledgementsStore.assetNotices {
            try write(asset.path, "\(asset.title) text\n")
        }
    }

    private func store() -> AcknowledgementsStore {
        AcknowledgementsStore(resourceRoot: root)
    }

    // MARK: - Inventory

    func testListsPackagedNoticesAndPerAssetTexts() throws {
        try writeCompleteTree()
        let (entries, problems) = store().inventory()
        XCTAssertEqual(problems, [])
        XCTAssertEqual(
            entries.map(\.id),
            ["ThirdPartyLicenses/Sparkle-LICENSE.txt",
             "Fonts/OFL-Geist.txt", "Fonts/OFL-GeistMono.txt", "Models/LICENSE-FastEnhancer.txt"],
            "the three per-asset texts live outside ThirdPartyLicenses and must not be dropped")
    }

    func testAnUnfamiliarFilenameStillAppears() throws {
        try writeCompleteTree()
        try write("ThirdPartyLicenses/brand-new-dependency-LICENSE.txt", "text\n")
        let entries = store().inventory().entries
        let entry = try XCTUnwrap(entries.first { $0.id.hasSuffix("brand-new-dependency-LICENSE.txt") })
        XCTAssertEqual(entry.title, "brand new dependency",
                       "a notice packaged later must be readable without a UI change")
    }

    func testOrderingIsStableAcrossReads() throws {
        try writeCompleteTree()
        for name in ["Zeta-LICENSE.txt", "alpha-LICENSE.txt", "Mid-LICENSE.txt"] {
            try write("ThirdPartyLicenses/\(name)", "text\n")
        }
        XCTAssertEqual(store().inventory().entries.map(\.id), store().inventory().entries.map(\.id))
    }

    func testIdentityStaysDistinctForIdenticalTexts() throws {
        try writeCompleteTree()
        try write("ThirdPartyLicenses/Twin-A-LICENSE.txt", "identical\n")
        try write("ThirdPartyLicenses/Twin-B-LICENSE.txt", "identical\n")
        let entries = store().inventory().entries
        let twins = entries.filter { $0.id.contains("Twin-") }
        XCTAssertEqual(twins.count, 2)
        XCTAssertEqual(Set(twins.map(\.id)).count, 2, "same text, still two notices")
    }

    // MARK: - Failure states

    func testMissingDirectoryIsReported() throws {
        for asset in AcknowledgementsStore.assetNotices { try write(asset.path, "text\n") }
        let (entries, problems) = store().inventory()
        XCTAssertTrue(problems.contains(.missingDirectory("ThirdPartyLicenses")))
        XCTAssertFalse(entries.isEmpty, "the per-asset texts still read")
    }

    func testEmptyDirectoryIsReported() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ThirdPartyLicenses"), withIntermediateDirectories: true)
        for asset in AcknowledgementsStore.assetNotices { try write(asset.path, "text\n") }
        XCTAssertTrue(store().inventory().problems.contains(.emptyInventory("ThirdPartyLicenses")))
    }

    func testEntirelyEmptyTreeReportsUnavailable() {
        let (entries, problems) = store().inventory()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(problems.isEmpty, "an empty bundle must not render as a blank success")
    }

    func testMissingPerAssetNoticeIsReportedNotSkipped() throws {
        try write("ThirdPartyLicenses/Sparkle-LICENSE.txt", "text\n")
        try write("Fonts/OFL-Geist.txt", "text\n")
        try write("Models/LICENSE-FastEnhancer.txt", "text\n")
        let (entries, problems) = store().inventory()
        XCTAssertTrue(problems.contains(.missingAsset("Fonts/OFL-GeistMono.txt")))
        XCTAssertTrue(entries.contains { $0.id == "Fonts/OFL-Geist.txt" },
                      "one missing notice must not hide the readable ones")
    }

    func testNoResourceRootIsReported() {
        let (entries, problems) = AcknowledgementsStore(resourceRoot: nil).inventory()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(problems, [.noResourceRoot])
    }

    // MARK: - Reading a notice

    func testReadsPackagedBytes() throws {
        try writeCompleteTree()
        let body = "Sparkle licence text\n"
        let entry = try XCTUnwrap(store().inventory().entries.first)
        guard case .success(let text) = store().text(for: entry) else {
            return XCTFail("expected the packaged text")
        }
        XCTAssertEqual(text, body, "the reader shows the file's bytes, not a copy in Swift")
    }

    func testUnreadableFileFailsWithoutFallingBackToAnotherNotice() throws {
        try writeCompleteTree()
        let entries = store().inventory().entries
        let entry = try XCTUnwrap(entries.first)
        try FileManager.default.removeItem(at: entry.url)
        guard case .failure(let problem) = store().text(for: entry) else {
            return XCTFail("a deleted notice must not read as success")
        }
        XCTAssertEqual(problem, .unreadable(entry.id))
    }

    func testInvalidUTF8IsReportedNotRendered() throws {
        try writeCompleteTree()
        let url = root.appendingPathComponent("ThirdPartyLicenses/Broken-LICENSE.txt")
        try Data([0xFF, 0xFE, 0x00, 0x9F]).write(to: url)
        let entry = try XCTUnwrap(store().inventory().entries.first { $0.url == url })
        guard case .failure(let problem) = store().text(for: entry) else {
            return XCTFail("invalid UTF-8 must not render as text")
        }
        XCTAssertEqual(problem, .notUTF8(entry.id))
    }

    func testEmptyNoticesFailInsteadOfRenderingBlank() throws {
        try writeCompleteTree()
        try write("ThirdPartyLicenses/Zero-LICENSE.txt", "")
        try write("Fonts/OFL-Geist.txt", "  \n\t\n")
        let entries = store().inventory().entries
        for id in ["ThirdPartyLicenses/Zero-LICENSE.txt", "Fonts/OFL-Geist.txt"] {
            let entry = try XCTUnwrap(entries.first { $0.id == id })
            guard case .failure(let problem) = store().text(for: entry) else {
                return XCTFail("\(id): an empty notice must not read as success")
            }
            XCTAssertEqual(problem, .empty(id))
        }
        let sibling = try XCTUnwrap(entries.first { $0.id == "Fonts/OFL-GeistMono.txt" })
        guard case .success = store().text(for: sibling) else {
            return XCTFail("one empty notice must not break its neighbours")
        }
    }

    func testNonEmptyTextIsReturnedVerbatim() throws {
        try writeCompleteTree()
        try write("ThirdPartyLicenses/Padded-LICENSE.txt", "\n  indented text\n\n")
        let entry = try XCTUnwrap(store().inventory().entries.first { $0.id.contains("Padded") })
        guard case .success(let text) = store().text(for: entry) else { return XCTFail("expected text") }
        XCTAssertEqual(text, "\n  indented text\n\n")
    }

    func testLargeMultilineNoticeReadsWhole() throws {
        try writeCompleteTree()
        let lines = (1...6_121).map { "line \($0) of a long third-party notice" }.joined(separator: "\n")
        try write("ThirdPartyLicenses/Huge-ThirdPartyNotices.txt", lines)
        let entry = try XCTUnwrap(store().inventory().entries.first { $0.id.contains("Huge") })
        guard case .success(let text) = store().text(for: entry) else {
            return XCTFail("expected the long notice to read")
        }
        XCTAssertEqual(text.components(separatedBy: "\n").count, 6_121)
        XCTAssertTrue(text.hasSuffix("line 6121 of a long third-party notice"),
                      "the final lines must be reachable, not truncated")
    }

    // MARK: - The guards are load-bearing

    func testTitleMapIsNotTheInventory() throws {
        try writeCompleteTree()
        try write("ThirdPartyLicenses/Unmapped-LICENSE.txt", "text\n")
        let entries = store().inventory().entries
        XCTAssertTrue(entries.contains { $0.id.hasSuffix("Unmapped-LICENSE.txt") },
                      "listing from the title map instead of the directory would omit this")
        XCTAssertNil(AcknowledgementsStore.titles["Unmapped-LICENSE.txt"])
    }

    func testFallbackTitleKeepsSomethingReadable() {
        XCTAssertEqual(AcknowledgementsStore.fallbackTitle(for: "some_new-thing-LICENSE.txt"),
                       "some new thing")
        XCTAssertEqual(AcknowledgementsStore.fallbackTitle(for: "x.txt"), "x")
    }
}
