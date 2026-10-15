import Foundation
import XCTest
@testable import Reed

final class SelfCorrectionThirdReviewTests: XCTestCase {
    func testDeletingSeveralLaterVersionsCannotKeepTheFirst() {
        let earlier = "We were going to leave the office."
        let revision = "We are going to leave the office."
        let latest = "We will leave the office."
        for suffix in ["", " Please call Maya."] {
            let input = earlier + " " + revision + " " + latest + suffix
            let wrong = earlier + suffix
            let correct = latest + suffix
            let badVerdict = CleanupGate.rejection(input: input, output: wrong, repairHint: true)
            let goodVerdict = CleanupGate.rejection(input: input, output: correct, repairHint: true)
            print("R3 chain \(suffix.debugDescription): wrong \(badVerdict?.rawValue ?? "accepted"), correct \(goodVerdict?.rawValue ?? "accepted")")
            XCTAssertNotNil(badVerdict)
            XCTAssertNil(goodVerdict)
        }
    }

    func testThreeDateRevisionsKeepTheFinalChoice() {
        let first = "I want to send this on Thursday morning."
        let second = "I want to send this on Friday morning."
        let last = "I want to send this on Monday morning."
        let input = first + " " + second + " " + last
        XCTAssertTrue(SentenceRevision.revises(previous: first, next: second))
        XCTAssertTrue(SentenceRevision.revises(previous: second, next: last))
        let wrong = CleanupGate.rejection(input: input, output: first, repairHint: true)
        let correct = CleanupGate.rejection(input: input, output: last, repairHint: true)
        print("R3 dates: wrong \(wrong?.rawValue ?? "accepted"), correct \(correct?.rawValue ?? "accepted")")
        XCTAssertNotNil(wrong)
        XCTAssertNil(correct)
    }

    func testQuotedCuesOnEitherSideNeverExcuseNegation() {
        for cue in ["\"sorry\"", "“sorry”"] {
            for (input, wrong) in [("Print the words \(cue), Friday, not Friday, Monday on the card.",
                                    "Print the words \(cue), Monday on the card."),
                                   ("Print the words Friday, not Friday, Monday, \(cue) on the card.",
                                    "Print the words Monday, \(cue) on the card.")] {
                XCTAssertNotNil(CleanupGate.rejection(input: input, output: wrong, repairHint: true))
            }
        }
    }

    func testOrdinaryUnmarkedCorrectionsStillPassInBothPositions() {
        let stems = ["going to go.", "planning to send it on Thursday.",
                     "planning to send the report on Thursday.",
                     "planning to send the completed report to the entire team before noon on Thursday."]
        for stem in stems {
            let earlier = "We were " + stem, latest = "We are " + stem
            for suffix in ["", " Please call Maya."] {
                let input = earlier + " " + latest + suffix
                XCTAssertNotNil(CleanupGate.rejection(input: input, output: earlier + suffix, repairHint: true))
                XCTAssertNil(CleanupGate.rejection(input: input, output: latest + suffix, repairHint: true))
            }
        }
    }

    /// (Rewritten for the fourth review: `deletesLaterVersion` was replaced
    /// by `losesFinalVersion`, judged on the input, not the aligned span.)
    func testAnIdenticalRepeatDoesNotBecomeABackwardsRevision() {
        let input = "We must ship it today. We must ship it today."
        XCTAssertNil(CleanupGate.rejection(input: input, output: "We must ship it today.", repairHint: true))
    }
    @available(macOS 26.0, *)
    func testTheProductionLoopRejectsKeepingTheFirstOfThreeVersions() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability required for stubbed loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "We were going to leave the office. We are going to leave the office. We will leave the office."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text("We were going to leave the office.") }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R3 production wrong proposal: \(outcome.text)")
        XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, input))
    }

    @available(macOS 26.0, *)
    func testTheProductionLoopAcceptsTheFinalOfThreeVersions() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability required for stubbed loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "We were going to leave the office. We are going to leave the office. We will leave the office."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text("We will leave the office.") }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R3 production correct proposal: \(outcome.text)")
        XCTAssertEqual(outcome.text, "We will leave the office.")
    }
}

final class SelfCorrectionThirdReviewAppleTests: XCTestCase {
    @available(macOS 26.0, *)
    func testTheActualAppleModelOnThreeVersions() async throws {
        guard ProcessInfo.processInfo.environment["REED_R3_APPLE"] == "1", AICleanup.isAvailable else {
            throw XCTSkip("Opt-in text-only Apple review")
        }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.ai)
        defer {
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let first = "We were going to leave the office."
        let second = "We are going to leave the office."
        let last = "We will leave the office."
        for cue in ["", "Scratch that. "] {
            for suffix in ["", " Please call Maya."] {
                let input = first + " " + second + " " + cue + last + suffix
                let collector = DictationReview(keepsContent: true)
                let outcome = await LocalCleanup.$observer.withValue(collector) { await LocalCleanup.applyWithPath(to: input) }
                let record = collector.finish(.init(injection: .init(text: outcome.text, target: nil, method: "review-no-insertion"),
                                                    timings: .init(totalSeconds: 0), mode: "review", engine: "none"))
                print("R3APPLE \(input.debugDescription) -> \(outcome.text.debugDescription)")
                print("R3TRACE \(String(data: try JSONEncoder().encode(record), encoding: .utf8)!)")
                // What the code guarantees: the final version is never lost.
                // Full resolution is model quality, printed above (2026-10-14:
                // unmarked chains resolve fully or to the last two versions;
                // the "Scratch that." variants are left as spoken).
                XCTAssertTrue(SelfCorrectionFixtures.fold(outcome.text).suffix(SelfCorrectionFixtures.fold(last + suffix).count)
                              == ArraySlice(SelfCorrectionFixtures.fold(last + suffix)), outcome.text)
            }
        }
    }
}
