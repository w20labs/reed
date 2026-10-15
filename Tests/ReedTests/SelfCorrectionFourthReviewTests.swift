import Foundation
import XCTest
@testable import Reed

final class SelfCorrectionFourthReviewTests: XCTestCase {
    func testTheFinalVersionSurvivesEverySubsetOfEarlierVersions() {
        let chains = [
            ["We were going to leave the office.", "We are going to leave the office.", "We will leave the office."],
            ["I want to send this on Thursday morning.", "I want to send this on Friday morning.", "I want to send this on Monday morning."],
        ]
        for chain in chains {
            for suffix in ["", " Please call Maya."] {
                for bits in 1..<8 {
                    let selected = chain.enumerated().filter { bits & (1 << $0.offset) != 0 }.map(\.element)
                    let verdict = CleanupGate.rejection(input: chain.joined(separator: " ") + suffix,
                                                         output: selected.joined(separator: " ") + suffix, repairHint: true)
                    if bits & 4 == 0 { XCTAssertNotNil(verdict, "\(bits): \(selected)") }
                    else { XCTAssertNil(verdict, "\(bits): \(selected)") }
                }
            }
        }
    }

    func testARevisionCannotLoseItsFinalVersionWhenASROmitsPeriods() {
        let chain = ["We were going to leave the office", "We are going to leave the office", "We will leave the office"]
        for separator in [" ", ", ", "; ", " — "] {
            let input = chain.joined(separator: separator) + "."
            let output = chain[0] + "."
            let reason = LocalCleanup.structuralReason(input)
            let wrong = CleanupGate.rejection(input: input, output: output, repairHint: reason != nil)
            let correct = CleanupGate.rejection(input: input, output: chain[2] + ".", repairHint: reason != nil)
            print("R4 punctuation \(separator.debugDescription) \(reason ?? "nil"): wrong \(wrong?.rawValue ?? "accepted"), correct \(correct?.rawValue ?? "accepted")")
            XCTAssertNotNil(wrong)
            XCTAssertNil(correct)
        }
    }

    func testTheFinalVersionSurvivesBeforeAnUnrelatedClauseWithoutPeriods() {
        let input = "We were going to leave the office, we are going to leave the office, we will leave the office, please call Maya."
        let wrong = "We were going to leave the office, please call Maya."
        let correct = "We will leave the office, please call Maya."
        let bad = CleanupGate.rejection(input: input, output: wrong, repairHint: true)
        let good = CleanupGate.rejection(input: input, output: correct, repairHint: true)
        print("R4 mid-clause: wrong \(bad?.rawValue ?? "accepted"), correct \(good?.rawValue ?? "accepted")")
        XCTAssertNotNil(bad)
        XCTAssertNil(good)
    }

    @available(macOS 26.0, *)
    func testTheProductionLoopKeepsTheFinalVersionWithoutPeriods() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability needed for stubbed model loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "We were going to leave the office, we are going to leave the office, we will leave the office."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text("We were going to leave the office.") }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R4 production comma chain: \(outcome.text)")
        XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, input))
    }

    func testAnUnrelatedSentenceAfterACueKeepsItsBoundary() {
        XCTAssertFalse(SentenceChunker.endsInNonFinalWord("Scratch that."))
        XCTAssertFalse(SentenceChunker.endsInNonFinalWord("Wait, scratch that."))
        XCTAssertTrue(SentenceChunker.endsInNonFinalWord("I think that."))
    }
}

final class SelfCorrectionFourthReviewAppleTests: XCTestCase {
    @available(macOS 26.0, *)
    func testTheFinalVersionIsKeptAcrossASRPunctuationVariants() async throws {
        guard ProcessInfo.processInfo.environment["REED_R4_APPLE"] == "1", AICleanup.isAvailable else {
            throw XCTSkip("Opt-in text-only Apple review")
        }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.ai)
        defer {
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let versions = ["We were going to leave the office", "We are going to leave the office", "We will leave the office"]
        for separator in [" ", ", ", "; ", " — "] {
            let input = versions.joined(separator: separator) + "."
            let collector = DictationReview(keepsContent: true)
            let outcome = await LocalCleanup.$observer.withValue(collector) { await LocalCleanup.applyWithPath(to: input) }
            let record = collector.finish(.init(injection: .init(text: outcome.text, target: nil, method: "review-no-insertion"),
                                               timings: .init(totalSeconds: 0), mode: "review", engine: "none"))
            print("R4APPLE \(separator.debugDescription) \(outcome.text.debugDescription)")
            print("R4TRACE \(String(data: try JSONEncoder().encode(record), encoding: .utf8)!)")
            XCTAssertEqual(Array(SelfCorrectionFixtures.fold(outcome.text).suffix(5)), SelfCorrectionFixtures.fold(versions[2]))
        }
    }
}
