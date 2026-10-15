import Foundation
import XCTest
@testable import Reed

final class SelfCorrectionNinthReviewTests: XCTestCase {
    func testCapitalizationChangesDoNotAddWords() {
        for (input, correct) in [
            ("We use api tokens.", "We use API tokens."),
            ("We use ai for cleanup.", "We use AI for cleanup."),
            ("Please send HELP today.", "Please send help today."),
            ("Do NOT ship it.", "Do not ship it."),
        ] {
            let verdict = CleanupGate.rejection(input: input, output: correct, repairHint: false)
            print("R9 case \(input) => \(correct): \(verdict?.rawValue ?? "accepted")")
            XCTAssertNil(verdict, input)
        }
    }

    func testARevisionCanCleanWhileCapitalizingAnAcronym() {
        let input = "We were planning to call the api today. We are planning to call the api today."
        let correct = "We are planning to call the API today."
        XCTAssertNil(CleanupGate.rejection(input: input, output: correct, repairHint: true))
    }

    func testTheRulesKeepAnAllCapsListEntry() {
        let input = "The event names are START, LIKE, STOP today."
        XCTAssertEqual(BasicCleanup.clean(input), input)
        XCTAssertNotNil(CleanupGate.rejection(input: input, output: "The event names are START STOP today.", repairHint: false))
    }

    @available(macOS 26.0, *)
    func testProductionKeepsAValidRevisionThatCorrectsAcronymCase() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability for stubbed loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "We were planning to call the api today. We are planning to call the api today."
        let correct = "We are planning to call the API today."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text(correct) }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R9 production case: \(outcome.text)")
        XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, correct))
    }

    @available(macOS 26.0, *)
    func testProductionKeepsAListEntryDuringTheFillerPostCheck() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability for stubbed loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "The event names were START, LIKE, STOP today. The event names are START, LIKE, STOP, uh, today."
        let modelProposal = "The event names are START, LIKE, STOP, uh, today."
        let correct = "The event names are START, LIKE, STOP today."
        XCTAssertNil(CleanupGate.rejection(input: input, output: modelProposal, repairHint: true))
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text(modelProposal) }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R9 production list entry: \(outcome.text)")
        XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, correct))
    }
}

final class SelfCorrectionNinthReviewAppleTests: XCTestCase {
    @available(macOS 26.0, *)
    func testAppleForAcronymCapitalizationAndLiteralListEntries() async throws {
        guard ProcessInfo.processInfo.environment["REED_R9_APPLE"] == "1", AICleanup.isAvailable else {
            throw XCTSkip("Opt-in text-only review")
        }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.ai)
        defer {
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let inputs = [
            "We use api tokens.",
            "We were planning to call the api today. We are planning to call the api today.",
            "The event names were START, LIKE, STOP today. The event names are START, LIKE, STOP, uh, today.",
        ]
        for input in inputs {
            let collector = DictationReview(keepsContent: true)
            let outcome = await LocalCleanup.$observer.withValue(collector) { await LocalCleanup.applyWithPath(to: input) }
            let record = collector.finish(.init(injection: .init(text: outcome.text, target: nil, method: "review-no-insertion"),
                                               timings: .init(totalSeconds: 0), mode: "review", engine: "none"))
            print("R9APPLE \(input.debugDescription) => \(outcome.text.debugDescription)")
            print("R9TRACE \(String(data: try JSONEncoder().encode(record), encoding: .utf8)!)")
        }
    }
}
