import Foundation
import XCTest
@testable import Reed

final class SelfCorrectionTenthReviewTests: XCTestCase {
    func testAnAdjacentLowercaseFragmentIsNotJudgedAsTheCapitalAcronym() {
        let cases = [
            ("The PR pr preparation is ready.", "The PR preparation is ready."),
            ("We need an AI ai air traffic controller.", "We need an AI air traffic controller."),
            ("The RE re rewrite is ready.", "The RE rewrite is ready."),
        ]
        for (input, correct) in cases {
            let verdict = CleanupGate.verdict(input: input, output: correct, repairHint: false)
            print("R10 adjacent \(input) => \(correct): \(verdict.rejection?.rawValue ?? "accepted")")
            for deletion in verdict.deletions { print("R10 map raw \(deletion.tokens), window \(deletion.window)") }
            XCTAssertNil(verdict.rejection, input)
        }
    }

    func testCaseFixesDoNotChangeWhichVersionSurvives() {
        let cases = [
            ("We were planning to use an AI air filter. We are planning to use an AI air filter.", "We are planning to use an ai air filter."),
            ("We were planning to use an ai air filter. We are planning to use an ai air filter.", "We are planning to use an AI air filter."),
            ("We were planning to use the AI air filter. We are planning to use the the AI air filter.", "We are planning to use the ai air filter."),
            ("We were planning to use the ai air filter. We are planning to use the the ai air filter.", "We are planning to use the AI air filter."),
        ]
        for (input, correct) in cases {
            let verdict = CleanupGate.rejection(input: input, output: correct, repairHint: true)
            print("R10 survival \(input) => \(correct): \(verdict?.rawValue ?? "accepted")")
            XCTAssertNil(verdict, input)
        }
        XCTAssertNil(CleanupGate.rejection(input: "We were planning to use an AI air filter. We are planning to use an AI air filter.", output: "We are planning to use an AI air filter.", repairHint: true))
    }

    @available(macOS 26.0, *)
    func testProductionAcceptsAdjacentFragmentCleanupAndARecasedFinalVersion() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability for stubbed loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        for (input, correct) in [
            ("The PR pr preparation is ready.", "The PR preparation is ready."),
            ("We were planning to use an ai air filter. We are planning to use an ai air filter.", "We are planning to use an AI air filter."),
        ] {
            LocalCleanup.modelCallOverrideForTests = { _, _ in .text(correct) }
            let outcome = await LocalCleanup.applyWithPath(to: input)
            print("R10 production \(input) => \(outcome.text)")
            XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, correct), input)
        }
    }
}

final class SelfCorrectionTenthReviewAppleTests: XCTestCase {
    @available(macOS 26.0, *)
    func testAppleForAdjacentFragmentsAndRecasedFinalVersions() async throws {
        guard ProcessInfo.processInfo.environment["REED_R10_APPLE"] == "1", AICleanup.isAvailable else {
            throw XCTSkip("Opt-in text-only review")
        }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.ai)
        defer {
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let inputs = [
            "The PR pr preparation is ready.",
            "We need an AI ai air traffic controller.",
            "We were planning to use an ai air filter. We are planning to use an ai air filter.",
            "We were planning to use the ai air filter. We are planning to use the the ai air filter.",
        ]
        for input in inputs {
            let collector = DictationReview(keepsContent: true)
            let outcome = await LocalCleanup.$observer.withValue(collector) { await LocalCleanup.applyWithPath(to: input) }
            let record = collector.finish(.init(injection: .init(text: outcome.text, target: nil, method: "review-no-insertion"),
                                               timings: .init(totalSeconds: 0), mode: "review", engine: "none"))
            print("R10APPLE \(input.debugDescription) => \(outcome.text.debugDescription)")
            print("R10TRACE \(String(data: try JSONEncoder().encode(record), encoding: .utf8)!)")
        }
    }
}
