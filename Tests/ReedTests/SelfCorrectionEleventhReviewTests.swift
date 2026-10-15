import XCTest
@testable import Reed

final class SelfCorrectionEleventhReviewTests: XCTestCase {
    func testTheFinalModalMustSurvive() {
        for modal in ["could", "can", "will", "would", "might"] {
            let input = "We should we \(modal) try the other vendor."
            let wrong = "We should try the other vendor."
            let correct = "We \(modal) try the other vendor."
            let hint = LocalCleanup.structuralReason(input) != nil
            let wrongVerdict = CleanupGate.rejection(input: input, output: wrong, repairHint: hint)
            let correctVerdict = CleanupGate.rejection(input: input, output: correct, repairHint: hint)
            print("R11 \(modal): wrong=\(wrongVerdict?.rawValue ?? "accepted") correct=\(correctVerdict?.rawValue ?? "accepted") hint=\(hint)")
            XCTAssertNotNil(wrongVerdict, "must refuse the abandoned should when final is \(modal)")
            XCTAssertNil(correctVerdict, "must accept the speaker's final \(modal)")
        }
    }

    @available(macOS 26.0, *)
    func testTheProductionLoopRefusesTheAbandonedModal() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability for controlled proposal") }
        let savedTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let savedOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = savedOverride
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let wrong = "We should try the other vendor."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text(wrong) }
        let out = await LocalCleanup.applyWithPath(to: "We should we could try the other vendor.")
        print("R11 production \(out.path.rawValue): \(out.text)")
        XCTAssertNotEqual(out.text, wrong)
    }
}
