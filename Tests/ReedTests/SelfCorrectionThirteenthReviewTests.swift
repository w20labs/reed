import XCTest
@testable import Reed

final class SelfCorrectionThirteenthReviewTests: XCTestCase {
    func testCueOnlyDeletionAfterPriorSentenceIsRefused() {
        let cases = [
            ("Our team has five. I mean, six open roles.", "Our team has five. Six open roles."),
            ("Send it to Anna. Sorry, send it to Maria.", "Send it to Anna. Send it to Maria.")
        ]
        for (input, harmful) in cases {
            let verdict = CleanupGate.rejection(input: input, output: harmful, repairHint: false)
            print("R13_GATE|\(input)|\(verdict?.rawValue ?? "accepted")")
            XCTAssertNotNil(verdict, input)
        }
    }

    func testCueOnlyDeletionAtTheStartOfAChunkIsRefused() {
        let input = "I mean, six open roles."
        let output = "Six open roles."
        let verdict = CleanupGate.rejection(input: input, output: output, repairHint: false)
        print("R13_OPENING_GATE|\(verdict?.rawValue ?? "accepted")")
        XCTAssertNotNil(verdict)
    }

    @available(macOS 26.0, *)
    func testCorrectionCueAfterParagraphBreakStaysInTheProductionOutput() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("availability for controlled text-only model reply") }
        let tier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let override = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = override
            if let tier { UserDefaults.standard.set(tier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        LocalCleanup.modelCallOverrideForTests = { text, _ in
            .text(text.hasPrefix("I mean") ? "Six open roles." : text)
        }
        let input = "Our team has five.\nI mean, six open roles."
        let result = await LocalCleanup.applyWithPath(to: input)
        print("R13_PARAGRAPH_PRODUCTION|\(result.path.rawValue)|\(result.text)")
        XCTAssertEqual(result.text, input)
    }

    @available(macOS 26.0, *)
    func testProductionDoesNotEraseTheCorrectionCueAfterSentenceBreak() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("availability for controlled text-only model reply") }
        let tier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let override = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = override
            if let tier { UserDefaults.standard.set(tier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let harmful = "Our team has five. Six open roles."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text(harmful) }
        let result = await LocalCleanup.applyWithPath(to: "Our team has five. I mean, six open roles.")
        print("R13_PRODUCTION|\(result.path.rawValue)|\(result.text)")
        XCTAssertNotEqual(result.text, harmful)
    }
}
