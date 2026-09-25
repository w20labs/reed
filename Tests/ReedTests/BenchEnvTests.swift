import XCTest
@testable import Reed

/// A bench that measures nothing must not pass (review 2026-09-01): empty
/// lists, comma-only lists, unknown names and zero counts are all errors.
final class BenchEnvTests: XCTestCase {
    private let engines: Set<String> = ["v2", "v3", "ctc110m"]

    func testDefaultsApplyWhenUnset() throws {
        XCTAssertEqual(try BenchEnv.list("K", default: "a,b", env: [:]), ["a", "b"])
        XCTAssertEqual(try BenchEnv.count("K", default: 5, env: [:]), 5)
    }

    func testEmptyAndCommaOnlyListsAreErrors() {
        for raw in ["", ",", ",,", " , ", "v3,"] {
            XCTAssertThrowsError(try BenchEnv.list("K", default: "x", env: ["K": raw]), "'\(raw)'")
        }
    }

    func testUnknownNamesAreErrorsAndKnownOnesPass() throws {
        XCTAssertThrowsError(try BenchEnv.list("K", default: "x", allowed: engines, env: ["K": "v33"]))
        XCTAssertThrowsError(try BenchEnv.list("K", default: "x", allowed: engines, env: ["K": "v3,ctc"]))
        XCTAssertEqual(try BenchEnv.list("K", default: "x", allowed: engines, env: ["K": " v3 ,v2"]), ["v3", "v2"])
    }

    /// A stage failure names the stage and carries the full reflected error,
    /// so a one-off like the 2026-09-01 DecodingError can never again escape
    /// a bench without saying which awaited call threw.
    func testStageFailureNamesTheStageAndKeepsTheError() async {
        struct Boom: Error {}
        do {
            _ = try await BenchStage.run("parakeet prepare") { () throws -> Int in throw Boom() }
            XCTFail("must rethrow")
        } catch let failure as BenchStage.Failure {
            XCTAssertEqual(failure.stage, "parakeet prepare")
            XCTAssertTrue(failure.underlying is Boom)
            XCTAssertTrue("\(failure)".contains("stage 'parakeet prepare' failed: ") && "\(failure)".contains("Boom"), "\(failure)")
        } catch { XCTFail("wrong error type: \(error)") }
        let value = try? await BenchStage.run("noop") { 42 }
        XCTAssertEqual(value, 42, "a stage that succeeds is transparent")
    }

    func testZeroNegativeAndNonNumericCountsAreErrors() {
        for raw in ["0", "-1", "", "five", "1.5"] {
            XCTAssertThrowsError(try BenchEnv.count("K", default: 5, env: ["K": raw]), "'\(raw)'")
        }
        XCTAssertEqual(try BenchEnv.count("K", default: 5, env: ["K": "1"]), 1)
    }
}
