import XCTest
@testable import Reed

/// Pins the hallucination guard: real cleanup / restructuring survives, but the
/// small model's "invent something unrelated" failure (the breakfast bug) is
/// rejected so the pipeline falls back to Basic rules.
final class CleanupFidelityTests: XCTestCase {
    func testFaithfulCleanupAccepted() {
        let input = "um so i think we should uh ship on monday"
        let output = "So I think we should ship on Monday."
        XCTAssertTrue(LocalCleanup.looksFaithful(
            input: input, output: output, minRecall: 0.5, maxGrowth: 3))
    }

    func testHallucinationRejectedForCleanupTier() {
        let input = "remind bob about the three pm meeting"
        let output = "Good morning! Here is a lovely breakfast menu: scrambled eggs, "
            + "toast, orange juice, and fresh coffee to start your day."
        XCTAssertFalse(LocalCleanup.looksFaithful(
            input: input, output: output, minRecall: 0.5, maxGrowth: 3))
    }

    func testHallucinationRejectedForFormattingMode() {
        let input = "remind bob about the three pm meeting"
        let output = "Good morning! Here is a lovely breakfast menu with eggs and toast."
        XCTAssertFalse(LocalCleanup.looksFaithful(
            input: input, output: output, minRecall: 0.25))
    }

    func testLegitEmailRestructureAccepted() {
        let input = "hey can you send bob the report about the meeting before friday"
        let output = "Hi Bob, could you please send over the report about the meeting "
            + "before Friday? Thanks so much."
        XCTAssertTrue(LocalCleanup.looksFaithful(
            input: input, output: output, minRecall: 0.25))
    }

    func testShortInputAlwaysAccepted() {
        // Under three words there's too little signal — never reject.
        XCTAssertTrue(LocalCleanup.looksFaithful(
            input: "hi there", output: "Totally unrelated sentence.", minRecall: 0.5, maxGrowth: 3))
    }
}
