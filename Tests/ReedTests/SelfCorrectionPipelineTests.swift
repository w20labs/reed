import XCTest
@testable import Reed

/// Natural self-correction through `LocalCleanup.applyWithPath` with the
/// model stubbed: chunking, routing, the gate and the rules fallback run as
/// in the app; the stub stands in for the Apple model's proposal (cleanup
/// QUALITY is measured against the real model in SelfCorrectionBenchTests).
final class SelfCorrectionPipelineTests: XCTestCase {
    /// What each chunk asked of the model, and with which prompt.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(String, Bool)] = []
        func add(_ chunk: String, _ repair: Bool) { lock.lock(); calls.append((chunk, repair)); lock.unlock() }
        var all: [(String, Bool)] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private func run(_ text: String, proposals: [String: String]) async throws -> (LocalCleanup.Outcome, [(String, Bool)]) {
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
        let calls = Calls()
        LocalCleanup.modelCallOverrideForTests = { chunk, repair in
            calls.add(chunk, repair)
            return .text(proposals[chunk] ?? chunk)
        }
        let outcome = await LocalCleanup.applyWithPath(to: text)
        return (outcome, calls.all)
    }

    /// P01: the pair reaches the model alone, on the repair prompt, and the
    /// model's correct deletion is delivered.
    func testAParagraphRevisionIsResolvedInItsOwnCall() async throws {
        let (outcome, calls) = try await run(
            "Can you send this to the team? We were going to go. We are going to go. Please update the calendar.",
            proposals: ["We were going to go. We are going to go.": "We are going to go."])
        XCTAssertTrue(calls.contains { $0.0 == "We were going to go. We are going to go." && $0.1 }, "\(calls)")
        XCTAssertEqual(outcome.text, "Can you send this to the team? We are going to go. Please update the calendar.")
    }

    /// M06: the model's correct repair of a negated option is delivered.
    func testANegatedAbandonedOptionResolves() async throws {
        let input = "The deadline is Friday, sorry, not Friday, Monday."
        let (outcome, _) = try await run(input, proposals: [input: "The deadline is Monday."])
        XCTAssertEqual(outcome.text, "The deadline is Monday.")
    }

    /// The protections hold on the production path: keeping the abandoned
    /// option, dropping a contrast or a whole elaborated sentence, and
    /// collapsing "had had" all fall back to the text as spoken.
    func testWrongProposalsFallBackToTheTextAsSpoken() async throws {
        for (input, wrong) in [("He has three, no wait, four kids.", "He has three kids."),
                               ("We were going to go, but we are going to stay.", "We were going to stay."),
                               ("We must test this. We must test this before release.", "We must test this before release."),
                               ("We had had several discussions before deciding.", "We had several discussions before deciding.")] {
            let (outcome, _) = try await run(input, proposals: [input: wrong])
            XCTAssertNotEqual(outcome.text, wrong, input)
            XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, input), "\(input) → \(outcome.text)")
        }
    }
}
