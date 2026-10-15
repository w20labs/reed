import Foundation
import XCTest
@testable import Reed

final class SelfCorrectionFifthReviewTests: XCTestCase {
    func testAnUnrelatedClauseCannotSupplyTheFinalVersionsChangedWord() {
        let chains = [
            ["We were going to leave the office", "we are going to leave the office", "we will leave the office"],
            ["I want to send this on Thursday morning", "I want to send this on Friday morning", "I want to send this on Monday morning"]
        ]
        let suffixes = ["Maya will call tomorrow.", "Monday is the next team meeting."]
        for (chain, suffix) in zip(chains, suffixes) {
            for separator in [" ", ", ", "; ", " — ", ". "] {
                let input = chain.joined(separator: separator) + ". " + suffix
                let wrong = chain[0] + ". " + suffix
                let correct = chain[2] + ". " + suffix
                let bad = CleanupGate.rejection(input: input, output: wrong, repairHint: true)
                let good = CleanupGate.rejection(input: input, output: correct, repairHint: true)
                print("R5 reuse \(separator.debugDescription) wrong \(bad?.rawValue ?? "accepted") correct \(good?.rawValue ?? "accepted"): \(input)")
                XCTAssertNotNil(bad, input)
                XCTAssertNil(good, input)
            }
        }
    }

    func testADifferentEarlierVersionCannotSupplyTheFinalChangedWord() {
        let input = "We will leave the office tomorrow, we are going to leave the office tomorrow, we will leave the office."
        let wrong = "We will leave the office tomorrow."
        XCTAssertNotNil(CleanupGate.rejection(input: input, output: wrong, repairHint: true))
        XCTAssertNil(CleanupGate.rejection(input: input, output: "We will leave the office.", repairHint: true))
    }

    func testAFinalVersionThatOnlyRemovesWordsStillSurvives() {
        let chains = [["We can approve the refund", "we approve the refund"]]
        for chain in chains {
            for separator in [" ", ", ", ". "] {
                let input = chain.joined(separator: separator) + "."
                let bad = CleanupGate.rejection(input: input, output: chain[0] + ".", repairHint: true)
                let good = CleanupGate.rejection(input: input, output: chain[1] + ".", repairHint: true)
                print("R5 subtract \(separator.debugDescription) wrong \(bad?.rawValue ?? "accepted") correct \(good?.rawValue ?? "accepted"): \(input)")
                XCTAssertNotNil(bad, input)
                XCTAssertNil(good, input)
            }
        }
    }

    func testPeriodSeparatedRevisionsStillRejectTheWrongVersionWithReusedWords() {
        let cases = [
            ("We were going to leave the office. We are going to leave the office. We will leave the office. Maya will call tomorrow.",
             "We were going to leave the office. Maya will call tomorrow."),
            ("We can approve the refund. We approve the refund.", "We can approve the refund.")
        ]
        for (input, wrong) in cases {
            XCTAssertNotNil(CleanupGate.rejection(input: input, output: wrong, repairHint: true), input)
        }
    }

    @available(macOS 26.0, *)
    func testTheProductionLoopRefusesTheEarlierVersionEvenWhenWillIsSpokenElsewhere() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability needed for stubbed loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "We were going to leave the office, we are going to leave the office, we will leave the office. Maya will call tomorrow."
        let wrong = "We were going to leave the office. Maya will call tomorrow."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text(wrong) }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R5 production \(outcome.text)")
        XCTAssertFalse(SelfCorrectionFixtures.matches(outcome.text, wrong))
    }
}

final class SelfCorrectionFifthReviewAppleTests: XCTestCase {
    @available(macOS 26.0, *)
    func testRealAppleOutputsForRepeatedChangedWordsAndSubtractiveRevisions() async throws {
        guard ProcessInfo.processInfo.environment["REED_R5_APPLE"] == "1", AICleanup.isAvailable else {
            throw XCTSkip("Opt-in text-only Apple review")
        }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.ai)
        defer {
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let inputs = [
            "We were going to leave the office, we are going to leave the office, we will leave the office. Maya will call tomorrow.",
            "I want to send this on Thursday morning, I want to send this on Friday morning, I want to send this on Monday morning. Monday is the next team meeting.",
            "We can approve the refund. We approve the refund.",
            "We are going to leave the office tomorrow. We are going to leave the office.",
        ]
        for input in inputs {
            let collector = DictationReview(keepsContent: true)
            let outcome = await LocalCleanup.$observer.withValue(collector) { await LocalCleanup.applyWithPath(to: input) }
            let record = collector.finish(.init(injection: .init(text: outcome.text, target: nil, method: "review-no-insertion"),
                                               timings: .init(totalSeconds: 0), mode: "review", engine: "none"))
            print("R5APPLE \(input.debugDescription) => \(outcome.text.debugDescription)")
            print("R5TRACE \(String(data: try JSONEncoder().encode(record), encoding: .utf8)!)")
            if input == "We can approve the refund. We approve the refund." {
                XCTAssertFalse(SelfCorrectionFixtures.matches(outcome.text, "We can approve the refund."), "Final version removed by the real model and accepted")
            }
        }
    }
}
