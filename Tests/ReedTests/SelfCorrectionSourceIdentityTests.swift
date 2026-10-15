import XCTest
@testable import Reed

/// Tenth review of PR #29: each source word keeps its identity, its written
/// case and its occurrence through alignment and repair classification, so a
/// proposal's formatting never changes whether that word carries meaning.
/// Combinations of acronyms, adjacent lowercase fragments (either order),
/// repeated fragments, case changes, fillers and grammatical doubles.
final class SelfCorrectionSourceIdentityTests: XCTestCase {
    static let validRepairs: [(String, String)] = [
        ("The PR pr preparation is ready.", "The PR preparation is ready."),
        ("The pr PR preparation is ready.", "The PR preparation is ready."),
        ("We need an AI ai ai air filter.", "We need an AI air filter."),
        ("The RE re rewrite is ready.", "The RE rewrite is ready."),
        ("We um had had several discussions.", "We had had several discussions."),
        ("We were going to call the api. We are going to call the api.", "We are going to call the API."),
        ("We were going to call the API. We are going to call the API.", "We are going to call the api."),
        // The versions differ only in an acronym's case: still one revision.
        ("We were using the AI tool. We are using the ai tool.", "We are using the ai tool."),
        ("We were planning to use the AI air filter. We are planning to uh use the the ai air filter.", "We are planning to use the AI air filter."),
        ("We were planning to use the AI air filter. We are planning to uh use the the ai air filter.", "We are planning to use the air filter."),
    ]

    static let meaningfulLosses: [(String, String)] = [
        ("We need an AI air filter.", "We need an air filter."),
        ("The pr PR preparation is ready.", "The pr preparation is ready."),
        ("We had had several discussions.", "We had several discussions."),
        ("We wanted six sixteen inch pizzas. We want six sixteen inch pizzas.", "We want sixteen inch pizzas."),
        ("We joined the UM team today.", "We joined the um team today."),
        ("We were planning to use the AI filter. We are planning to use the AI air filter.", "We are planning to use the air filter."),
        ("We were told. We had had several discussions.", "We had several discussions."),
    ]

    /// The repair hint production would compute for the input.
    private func hint(_ input: String) -> Bool { LocalCleanup.structuralReason(input) != nil }

    func testValidRepairsPassTheGate() {
        for (input, proposal) in Self.validRepairs {
            XCTAssertNil(CleanupGate.rejection(input: input, output: proposal, repairHint: hint(input)), "\(input) → \(proposal)")
        }
    }

    func testMeaningfulWordsMustSurviveTheGate() {
        for (input, proposal) in Self.meaningfulLosses {
            XCTAssertNotNil(CleanupGate.rejection(input: input, output: proposal, repairHint: hint(input)), "\(input) → \(proposal)")
        }
    }

    /// The source decides what a repair may drop; the proposal's case does not.
    func testRepairablePositionsComeFromTheSourceAsWritten() {
        let input = "We need an AI ai ai air filter."
        let keys = CleanupGate.caseKeys(input, tokens: CleanupGate.tokens(of: input))
        XCTAssertEqual(CleanupGate.repairablePositions(keys), [4, 5], "the lowercase fragments, never the acronym")
        XCTAssertTrue(CleanupGate.survives(keys, in: ["we", "need", "an", "ai", "air", "filter"]))
        XCTAssertFalse(CleanupGate.survives(keys, in: ["we", "need", "an", "air", "filter"]))
    }

    /// The production loop, with controlled proposals standing in for the model.
    func testTheProductionLoopDeliversValidRepairsAndRefusesLosses() async throws {
        guard #available(macOS 26.0, *), AICleanup.isAvailable else {
            throw XCTSkip("model-loop routing requires macOS 26 with Apple Intelligence; model calls are stubbed")
        }
        let savedTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let savedOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = savedOverride
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        for (input, proposal) in Self.validRepairs {
            LocalCleanup.modelCallOverrideForTests = { _, _ in .text(proposal) }
            let out = await LocalCleanup.applyWithPath(to: input).text
            XCTAssertTrue(SelfCorrectionFixtures.matches(out, proposal), "\(input) → \(out)")
        }
        for (input, proposal) in Self.meaningfulLosses {
            LocalCleanup.modelCallOverrideForTests = { _, _ in .text(proposal) }
            let out = await LocalCleanup.applyWithPath(to: input).text
            XCTAssertNotEqual(out, proposal, "\(input) → \(out)")
        }
    }
}
