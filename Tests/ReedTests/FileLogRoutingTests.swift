import XCTest
@testable import Reed

/// Review 2026-09-04 (round 3): a QA row's log tripwire must judge the
/// lines that row's run wrote. The QA runner names a per-run file through
/// the environment; a test process honours it, the app never does.
final class FileLogRoutingTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/reed-support", isDirectory: true)

    func testATestProcessHonoursTheRunnersRedirect() {
        let url = FileLog.resolveFile(in: dir, isTests: true, environment: [FileLog.testLogFileKey: "/tmp/qa/unit_core.txt.app.log"])
        XCTAssertEqual(url.path, "/tmp/qa/unit_core.txt.app.log")
    }

    func testATestProcessWithoutARedirectUsesItsOwnFile() {
        XCTAssertEqual(FileLog.resolveFile(in: dir, isTests: true, environment: [:]).lastPathComponent, "reed-tests.log")
        XCTAssertEqual(FileLog.resolveFile(in: dir, isTests: true, environment: [FileLog.testLogFileKey: ""]).lastPathComponent, "reed-tests.log")
    }

    func testTheAppNeverHonoursTheRedirect() {
        let url = FileLog.resolveFile(in: dir, isTests: false, environment: [FileLog.testLogFileKey: "/tmp/elsewhere.log"])
        XCTAssertEqual(url.lastPathComponent, "reed.log")
        XCTAssertEqual(url.deletingLastPathComponent().path, dir.path)
    }

    func testThisTestProcessWritesWhereItSaysItDoes() throws {
        // The live file is the resolver's answer for this process's environment.
        let expected = FileLog.resolveFile(in: FileLog.fileURL.deletingLastPathComponent(), isTests: true,
                                           environment: ProcessInfo.processInfo.environment)
        XCTAssertEqual(FileLog.fileURL.path, expected.path)
    }
}
