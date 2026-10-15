import Foundation
import XCTest
@testable import Reed

final class SelfCorrectionEighthReviewTests: XCTestCase {
    func testAnAcronymDoesNotTurnASeparateFragmentIntoAnAcronym() {
        let cases = [
            ("The PR is ready. Please pr prepare the notes.", "The PR is ready. Please prepare the notes."),
            ("Please pr prepare the notes. The PR is ready.", "Please prepare the notes. The PR is ready."),
            ("RE means reply. Please re rework the plan.", "RE means reply. Please rework the plan."),
        ]
        XCTAssertNil(CleanupGate.rejection(input: "Please pr prepare the notes.", output: "Please prepare the notes.", repairHint: false))
        for (input, correct) in cases {
            let verdict = CleanupGate.rejection(input: input, output: correct, repairHint: false)
            print("R8 occurrence \(input) => \(correct): \(verdict?.rawValue ?? "accepted")")
            XCTAssertNil(verdict, input)
        }
    }

    func testAcronymProtectionIsLocalWithinTheFinalVersion() {
        let input = "We were reviewing the PR before preparing the notes. We are reviewing the PR before pr preparing the notes."
        let correct = "We are reviewing the PR before preparing the notes."
        XCTAssertNil(CleanupGate.rejection(input: input, output: correct, repairHint: true))
    }

    func testAnUppercaseAcronymThatMatchesAFillerIsStillContent() {
        for acronym in ["UM", "ER"] {
            let input = "We are assigned to the \(acronym) team."
            let wrong = "We are assigned to the team."
            XCTAssertNotNil(CleanupGate.rejection(input: input, output: wrong, repairHint: false), acronym)
        }
    }

    @available(macOS 26.0, *)
    func testProductionAcceptsAFragmentRepairBesideASeparateAcronym() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability for stubbed loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "The PR is ready. Please pr prepare the notes."
        let correct = "The PR is ready. Please prepare the notes."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text(correct) }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R8 production occurrence: \(outcome.text)")
        XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, correct))
    }

    @available(macOS 26.0, *)
    func testProductionKeepsAnAcronymAfterASuccessfulRevisionCleanup() async throws {
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
            ("We were assigned to the UM research team. We are assigned to the UM research team.", "We are assigned to the UM research team."),
            ("We were planning to send the completed report to the UM research team tomorrow. We are planning to send the completed report to the UM research team tomorrow.", "We are planning to send the completed report to the UM research team tomorrow."),
        ] {
            XCTAssertNil(CleanupGate.rejection(input: input, output: correct, repairHint: true))
            LocalCleanup.modelCallOverrideForTests = { _, _ in .text(correct) }
            let outcome = await LocalCleanup.applyWithPath(to: input)
            print("R8 production acronym: \(outcome.text)")
            XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, correct), input)
        }
    }
}

final class SelfCorrectionEighthReviewAppleTests: XCTestCase {
    @available(macOS 26.0, *)
    func testAppleForAcronymOccurrencesAndPostCleanup() async throws {
        guard ProcessInfo.processInfo.environment["REED_R8_APPLE"] == "1", AICleanup.isAvailable else {
            throw XCTSkip("Opt-in text-only review")
        }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.ai)
        defer {
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let inputs = [
            "The PR is ready. Please pr prepare the notes.",
            "Please pr prepare the notes. The PR is ready.",
            "We were reviewing the PR before preparing the notes. We are reviewing the PR before pr preparing the notes.",
            "We were assigned to the UM research team. We are assigned to the UM research team.",
            "We were planning to send the completed report to the UM research team tomorrow. We are planning to send the completed report to the UM research team tomorrow.",
        ]
        for input in inputs {
            let collector = DictationReview(keepsContent: true)
            let outcome = await LocalCleanup.$observer.withValue(collector) { await LocalCleanup.applyWithPath(to: input) }
            let record = collector.finish(.init(injection: .init(text: outcome.text, target: nil, method: "review-no-insertion"),
                                               timings: .init(totalSeconds: 0), mode: "review", engine: "none"))
            print("R8APPLE \(input.debugDescription) => \(outcome.text.debugDescription)")
            print("R8TRACE \(String(data: try JSONEncoder().encode(record), encoding: .utf8)!)")
        }
    }
}
