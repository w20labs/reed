import XCTest
@testable import Reed

/// The ceilings loader fails closed (review 2026-09-01): a missing or
/// malformed file, or a non-numeric leaf, is an error — never "measured,
/// not gated". Only an absent key is nil, and `require` refuses even that.
final class BenchBaselinesTests: XCTestCase {
    private func file(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baselines-\(UUID().uuidString).json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReadsANestedNumber() throws {
        let url = try file(#"{"p1": {"e2e_p95_ms": {"v3": 2000, "ctc110m": 3200.5}}}"#)
        XCTAssertEqual(try BenchBaselines.ceiling(["p1", "e2e_p95_ms", "v3"], file: url), 2000)
        XCTAssertEqual(try BenchBaselines.require(["p1", "e2e_p95_ms", "ctc110m"], file: url), 3200.5)
    }

    func testAnAbsentKeyIsNilButRequireRefusesIt() throws {
        let url = try file(#"{"p1": {"e2e_p95_ms": {"v3": 2000}}}"#)
        XCTAssertNil(try BenchBaselines.ceiling(["p1", "e2e_p95_ms", "ctc110m"], file: url))
        XCTAssertNil(try BenchBaselines.ceiling(["asr", "wer_max_pct", "v3"], file: url))
        XCTAssertThrowsError(try BenchBaselines.require(["p1", "e2e_p95_ms", "ctc110m"], file: url)) { error in
            XCTAssertTrue("\(error)".contains("no committed ceiling"), "\(error)")
        }
    }

    func testAMissingFileThrowsInsteadOfDisarming() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertThrowsError(try BenchBaselines.ceiling(["gate", "max_refusals"], file: url)) { error in
            XCTAssertTrue("\(error)".contains("unreadable"), "\(error)")
        }
    }

    func testAMalformedFileThrowsInsteadOfDisarming() throws {
        let url = try file("{not json")
        XCTAssertThrowsError(try BenchBaselines.ceiling(["gate", "max_refusals"], file: url)) { error in
            XCTAssertTrue("\(error)".contains("malformed"), "\(error)")
        }
    }

    func testANonNumericLeafThrows() throws {
        let url = try file(#"{"gate": {"max_refusals": "ten", "flag": true}, "p1": 5}"#)
        XCTAssertThrowsError(try BenchBaselines.ceiling(["gate", "max_refusals"], file: url))
        XCTAssertThrowsError(try BenchBaselines.ceiling(["gate", "flag"], file: url), "a boolean is not a ceiling")
        XCTAssertThrowsError(try BenchBaselines.ceiling(["p1", "e2e_p95_ms", "v3"], file: url), "a number where an object is expected")
    }

    /// The committed file itself: every known arm the benches require is
    /// present and numeric, so the benches can never start ungated.
    func testTheCommittedFileCoversEveryKnownArm() throws {
        XCTAssertGreaterThan(try BenchBaselines.require(["gate", "max_refusals"]), 0)
        for arm in Phase1LatencyBenchTests.knownArms {
            XCTAssertGreaterThan(try BenchBaselines.require(["p1", "e2e_p95_ms", arm]), 0, arm)
        }
        for engine in ASREngineBenchTests.knownEngines {
            XCTAssertGreaterThan(try BenchBaselines.require(["asr", "wer_max_pct", engine]), 0, engine)
            XCTAssertGreaterThan(try BenchBaselines.require(["asr", "p50_max_ms", engine]), 0, engine)
        }
    }
}
