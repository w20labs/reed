import Foundation
import XCTest
@testable import Reed

final class SelfCorrectionSeventhReviewTests: XCTestCase {
    func testRepeatedStuttersInsideTheFinalVersionAreRepairable() {
        let cases = [
            ("We were planning to change the default setting.", "We are planning to c c change the default setting.", "We are planning to change the default setting."),
            ("We were planning to change the default setting.", "We are planning to c c c change the default setting.", "We are planning to change the default setting."),
            ("We were planning to rework the default setting.", "We are planning to re re rework the default setting.", "We are planning to rework the default setting."),
        ]
        for (earlier, final, correct) in cases {
            let input = earlier + " " + final
            let rejection = CleanupGate.rejection(input: input, output: correct, repairHint: true)
            print("R7 stutter \(input) => \(correct): \(rejection?.rawValue ?? "accepted")")
            XCTAssertNil(rejection, input)
        }
    }

    func testAGrammaticalHadHadSurvivesTheFinalVersionNormalization() {
        let words = ["we", "had", "had", "several", "discussions"]
        XCTAssertEqual(CleanupGate.repaired(words), words)
        let cases = [
            ("We have had several discussions. We had had several discussions.", "We had several discussions."),
            ("We have had several discussions, we had had several discussions.", "We had several discussions."),
        ]
        for (input, wrong) in cases {
            let rejection = CleanupGate.rejection(input: input, output: wrong, repairHint: true)
            print("R7 had \(input) => \(wrong): \(rejection?.rawValue ?? "accepted")")
            XCTAssertNotNil(rejection, input)
        }
    }

    func testTwoLetterAcronymsAreContentRatherThanFragments() {
        for (input, wrong) in [
            ("We need an AI air traffic controller.", "We need an air traffic controller."),
            ("We wanted an AI air traffic controller. We want an AI air traffic controller.", "We want an air traffic controller."),
        ] {
            let rejection = CleanupGate.rejection(input: input, output: wrong, repairHint: false)
            print("R7 acronym \(input) => \(wrong): \(rejection?.rawValue ?? "accepted")")
            XCTAssertNotNil(rejection, input)
        }
    }

    @available(macOS 26.0, *)
    func testProductionAcceptsARepeatedStutterRepairInsideTheFinalVersion() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability for stubbed loop") }
        let savedTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let savedOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = savedOverride
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "We were planning to change the default setting. We are planning to c c change the default setting."
        let correct = "We are planning to change the default setting."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text(correct) }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R7 production stutter: \(outcome.text)")
        XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, correct))
    }
    @available(macOS 26.0, *)
    func testProductionRefusesToDropGrammaticalWordsAndAcronyms() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability for stubbed loop") }
        let savedTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let savedOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = savedOverride
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        for (input, wrong) in [
            ("We have had several discussions. We had had several discussions.", "We had several discussions."),
            ("We wanted an AI air traffic controller. We want an AI air traffic controller.", "We want an air traffic controller."),
        ] {
            LocalCleanup.modelCallOverrideForTests = { _, _ in .text(wrong) }
            let outcome = await LocalCleanup.applyWithPath(to: input)
            print("R7 production meaning: \(input) => \(outcome.text)")
            XCTAssertFalse(SelfCorrectionFixtures.matches(outcome.text, wrong), input)
        }
    }

}

final class SelfCorrectionSeventhReviewAppleTests: XCTestCase {
    @available(macOS 26.0, *)
    func testRealAppleForRepeatedStuttersAndMeaningfulRepeats() async throws {
        guard ProcessInfo.processInfo.environment["REED_R7_APPLE"] == "1", AICleanup.isAvailable else {
            throw XCTSkip("Opt-in text-only review")
        }
        let savedTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.ai)
        defer {
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let inputs = [
            "We were planning to change the default setting. We are planning to c c change the default setting.",
            "We were planning to change the default setting. We are planning to c c c change the default setting.",
            "We were planning to rework the default setting. We are planning to re re rework the default setting.",
            "We have had several discussions. We had had several discussions.",
            "We wanted an AI air traffic controller. We want an AI air traffic controller.",
        ]
        for input in inputs {
            let collector = DictationReview(keepsContent: true)
            let outcome = await LocalCleanup.$observer.withValue(collector) { await LocalCleanup.applyWithPath(to: input) }
            let record = collector.finish(.init(injection: .init(text: outcome.text, target: nil, method: "review-no-insertion"),
                                               timings: .init(totalSeconds: 0), mode: "review", engine: "none"))
            print("R7APPLE \(input.debugDescription) => \(outcome.text.debugDescription)")
            print("R7TRACE \(String(data: try JSONEncoder().encode(record), encoding: .utf8)!)")
        }
    }
}
