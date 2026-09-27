import XCTest
@testable import Reed

/// A markdown link whose target is interpolated into a `LocalizedStringKey`
/// (`LocalizedStringKey("…](\(url))")`, `Text("…](\(url))")`,
/// `Text(.init("…](\(url))"))`) gets "%@" as its target, and clicking it fails
/// with -50. Settings › Privacy's "See exactly what Reed connects to" shipped
/// that way in 0.3.0.
final class SettingsLinkTests: XCTestCase {
    func testPrivacyFooterLinksToTheWhatWeCollectPage() throws {
        let links = markdownAttributed(ReedLinks.connectionsFooter).runs.compactMap(\.link)
        XCTAssertEqual(links, [try XCTUnwrap(URL(string: ReedLinks.privacyWhatWeCollect))])
    }

    func testNoLinkTargetIsInterpolatedIntoALocalizedStringKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        // The call (a whole name: markdownText( is the safe path), then its
        // string literal, possibly split across lines and joined with "+", up
        // to a link target that starts with "\(".
        let pattern = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])(LocalizedStringKey\(|Text\(\.init\(|Text\()\s*"(?:[^"\n]|"\s*\+\s*")*\]\(\\\("#
        )
        var scanned = 0
        var offenders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            scanned += 1
            let code = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            for match in pattern.matches(in: code, range: range) {
                offenders.append("\(file.lastPathComponent): \((code as NSString).substring(with: match.range))")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan must actually read the app's sources")
        XCTAssertEqual(offenders, [], "build these with markdownText(_:) instead")
    }
}
