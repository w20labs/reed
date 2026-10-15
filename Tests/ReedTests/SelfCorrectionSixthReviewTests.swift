import Foundation
import XCTest
@testable import Reed

final class SelfCorrectionSixthReviewTests: XCTestCase {
    func testPartialRepairsInsideTheFinalVersionAreStillAllowed() {
        let first = "We were going to leave the office. "
        let cases = [
            ("We will will l leave the office.", "We will l leave the office."),
            ("We will will l leave the office.", "We will will leave the office."),
            ("We will will leave the the office.", "We will leave the the office."),
            ("We will uh leave the office.", "We will uh leave the office."),
        ]
        for (last, proposed) in cases {
            let input = first + last
            let verdict = CleanupGate.rejection(input: input, output: proposed, repairHint: true)
            print("R6 partial \(input) => \(proposed): \(verdict?.rawValue ?? "accepted")")
            XCTAssertNil(verdict, input)
        }
    }

    func testRealWordsThatPrefixAnotherWordStayInTheFinalVersion() {
        let cases = [
            ("We wanted six sixteen inch pizzas. We want six sixteen inch pizzas.", "We want sixteen inch pizzas."),
            ("We can set per person limits. We will set per person limits.", "We will set person limits."),
            ("We wanted ten tenth floor rooms. We want ten tenth floor rooms.", "We want tenth floor rooms."),
            ("We wanted one one bedroom flat. We want one one bedroom flat.", "We want one bedroom flat."),
        ]
        for (input, proposed) in cases {
            let verdict = CleanupGate.rejection(input: input, output: proposed, repairHint: true)
            print("R6 word \(input) => \(proposed): \(verdict?.rawValue ?? "accepted")")
            XCTAssertNotNil(verdict, input)
        }
    }

    func testAPartiallyRepairedFinalVersionSurvives() {
        let input = "We were planning to leave the office. We are planning to l leave the the office."
        let output = "We are planning to leave the the office."
        XCTAssertNil(CleanupGate.rejection(input: input, output: output, repairHint: true))
    }

    func testAQuantityIsNotNormalizedAwayWhenJudgingAWholeSentenceDeletion() {
        let before = "we ordered six sixteen inch pizzas".split(separator: " ").map(String.init)
        let after = "we ordered sixteen inch sandwiches".split(separator: " ").map(String.init)
        XCTAssertFalse(CleanupGate.isRevisionStep(from: before, to: after))
    }

    func testAnUnchangedRevisionWithAFillerIsAccepted() {
        let input = "Actually, we were going to leave the office. We will uh leave the office."
        XCTAssertNil(CleanupGate.rejection(input: input, output: input, repairHint: true))
    }

    @available(macOS 26.0, *)
    func testTheProductionLoopKeepsTheQuantityInsideTheFinalVersion() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability for stubbed loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "We wanted six sixteen inch pizzas. We want six sixteen inch pizzas."
        let wrong = "We want sixteen inch pizzas."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text(wrong) }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R6 production quantity: \(outcome.text)")
        XCTAssertFalse(SelfCorrectionFixtures.matches(outcome.text, wrong))
    }
    @available(macOS 26.0, *)
    func testTheProductionLoopAllowsItsFillerPostCheckToRun() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability for stubbed loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "Actually, we were going to leave the office. We will uh leave the office."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text("We will uh leave the office.") }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R6 production filler: \(outcome.text)")
        XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, "We will leave the office."))
    }

}

final class SelfCorrectionSixthReviewAppleTests: XCTestCase {
    @available(macOS 26.0, *)
    func testAppleModelForPrefixWordsAndPartiallyRepairedVersions() async throws {
        guard ProcessInfo.processInfo.environment["REED_R6_APPLE"] == "1", AICleanup.isAvailable else {
            throw XCTSkip("Opt-in text-only review")
        }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.ai)
        defer {
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let inputs = [
            "We ordered six sixteen inch pizzas. We ordered sixteen inch sandwiches.",
            "We wanted six sixteen inch pizzas. We want six sixteen inch pizzas.",
            "We wanted ten tenth floor rooms. We want ten tenth floor rooms.",
            "We can set per person limits. We will set per person limits.",
            "We were planning to leave the office. We are planning to l leave the the office.",
            "Actually, we were going to leave the office. We will uh leave the office.",
        ]
        for input in inputs {
            let collector = DictationReview(keepsContent: true)
            let outcome = await LocalCleanup.$observer.withValue(collector) { await LocalCleanup.applyWithPath(to: input) }
            let record = collector.finish(.init(injection: .init(text: outcome.text, target: nil, method: "review-no-insertion"),
                                               timings: .init(totalSeconds: 0), mode: "review", engine: "none"))
            print("R6APPLE \(input.debugDescription) => \(outcome.text.debugDescription)")
            print("R6TRACE \(String(data: try JSONEncoder().encode(record), encoding: .utf8)!)")
        }
    }
}
