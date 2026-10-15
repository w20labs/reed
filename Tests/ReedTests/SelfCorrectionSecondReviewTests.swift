import Foundation
import XCTest
@testable import Reed

final class SelfCorrectionSecondReviewTests: XCTestCase {
    func testAQuotedCueOutsideTheDeletionCannotExcuseNegation() {
        for quote in [("\"", "\""), ("“", "”")] {
            let input = "Print the words \(quote.0)sorry\(quote.1), Friday, not Friday, Monday on the card."
            let output = "Print the words \(quote.0)sorry\(quote.1), Monday on the card."
            let reason = LocalCleanup.structuralReason(input)
            let verdict = CleanupGate.rejection(input: input, output: output, repairHint: reason != nil)
            print("R2 adjacent quoted cue: \(reason ?? "nil") \(verdict?.rawValue ?? "accepted")")
            XCTAssertEqual(verdict, .negationChanged)
        }
    }

    func testAQuotedWholeSentenceDoesNotBypassItsRefusal() {
        for quote in [("\"", "\""), ("“", "”")] {
            let input = quote.0 + "We were going to go yesterday. We are going to go tomorrow." + quote.1
            let output = quote.0 + "We are going to go tomorrow." + quote.1
            XCTAssertNotNil(CleanupGate.rejection(input: input, output: output, repairHint: true))
        }
    }

    @available(macOS 26.0, *)
    func testTheProductionPipelinePreservesTheQuotedContrast() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple availability required for stubbed loop") }
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let oldOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = oldOverride
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let input = "\"We were going to go yesterday. We are going to go tomorrow.\""
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text("\"We are going to go tomorrow.\"") }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("R2 quoted contrast pipeline: \(outcome.text)")
        XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, input))
    }

    func testTheEarlierVersionOfALongRevisionIsRejected() {
        let stems = ["planning to send it on Thursday.", "planning to send the report on Thursday.",
                     "planning to send the completed report to the entire team before noon on Thursday."]
        for stem in stems {
            let earlier = "We were " + stem
            let latest = "We are " + stem
            let input = earlier + " " + latest
            let hint = LocalCleanup.structuralReason(input) != nil
            let verdict = CleanupGate.rejection(input: input, output: earlier, repairHint: hint)
            print("R2 backwards \(earlier.split(separator: " ").count) words: \(verdict?.rawValue ?? "accepted")")
            XCTAssertNotNil(verdict)
        }
    }

    func testParagraphBoundarySplitsPreserveAllSeparators() {
        for head in ["Intro.\n\nWe were going to go.", "Intro.  We were going to go.", "Intro.\tWe were going to go."] {
            let split = Coordinator.splitLastSentence(head)
            XCTAssertEqual(split.before + split.last, head)
            XCTAssertEqual(split.last, "We were going to go.")
        }
        for tail in ["We are going to go.\n\nThanks.", "We are going to go.  Thanks.", "We are going to go.\tThanks."] {
            let split = Coordinator.splitFirstSentence(tail)
            XCTAssertEqual(split.first + split.after, tail)
            XCTAssertEqual(split.first, "We are going to go.")
        }
    }

    func testARevisionPairRemainsBoundedAtTheConfiguredLimit() {
        let pair = "We were planning to send the completed report to the entire team before noon on Thursday. We are planning to send the completed report to the entire team before noon on Thursday."
        for coalesce in [false, true] {
            for glue in [false, true] {
                let chunks = SentenceChunker.chunks(pair, coalesce: coalesce, glueFragments: glue)
                XCTAssertEqual(chunks.count, 1)
                XCTAssertEqual(chunks.first?.text, pair)
                let large = pair + " Actually, no, " + Array(repeating: "additional", count: 80).joined(separator: " ") + "."
                XCTAssertTrue(SentenceChunker.chunks(large, coalesce: coalesce, glueFragments: glue)
                    .allSatisfy { $0.text.split(whereSeparator: \.isWhitespace).count <= 32 })
            }
        }
    }
}
