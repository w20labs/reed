import Foundation
import XCTest
@testable import Reed

final class SelfCorrectionReviewerTests: XCTestCase {
    func testAReplacedModalMayStillOccurElsewhere() {
        let input = "We should we must finish today, and we should check the logs."
        let output = "We must finish today, and we should check the logs."
        let verdict = CleanupGate.rejection(input: input, output: output, repairHint: true)
        print("REVIEW modal gate: \(verdict?.rawValue ?? "accepted")")
        XCTAssertNil(verdict)
    }

    @MainActor
    func testRevisionAssemblyPreservesParagraphBreaks() async {
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.off)
        defer {
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let head = "Introduction.\nWe were going to go."
        let next = "We are going to go.\nPlease update the calendar."
        let result = await Coordinator.assembleSegments([.init(text: head, sealedBy: .pause), .init(text: next, sealedBy: nil)])
        print("REVIEW paragraphs: \(result.debugDescription)")
        XCTAssertEqual(result, head + " " + next)
    }

    func testAPairOfSixteenWordRevisionsReachesOneCall() {
        let a = "We were planning to send the completed report to the entire team before noon on Thursday."
        let b = "We are planning to send the completed report to the entire team before noon on Thursday."
        XCTAssertTrue(SentenceRevision.revises(previous: a, next: b))
        let chunks = SentenceChunker.chunks(a + " " + b, coalesce: true, glueFragments: true)
        print("REVIEW long revision: \(chunks)")
        XCTAssertEqual(chunks.count, 1)
    }

    func testAQuotedNegationIsNotACorrectionLicence() {
        let input = "The example is \"Friday, sorry, not Friday, Monday\" and we should keep it in the training guide for every new employee."
        XCTAssertNotNil(CleanupGate.rejection(input: input, output: "We should keep it in the training guide for every new employee.", repairHint: false))
    }

    @available(macOS 26.0, *)
    func testProductionPipelineRejectsDeletingAQuotedNegation() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple model availability needed for stubbed loop") }
        let savedTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let savedOverride = LocalCleanup.modelCallOverrideForTests
        LocalCleanup.setTier(.ai)
        defer {
            LocalCleanup.modelCallOverrideForTests = savedOverride
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text("We should keep it in the training guide for every new employee.") }
        let input = "The example is \"Friday, sorry, not Friday, Monday\" and we should keep it in the training guide for every new employee."
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("REVIEW quoted negation pipeline: \(outcome.text.debugDescription)")
        XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, input))
    }

    @available(macOS 26.0, *)
    func testProductionPipelineAcceptsAModalStillUsedElsewhere() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("Apple model availability needed for stubbed loop") }
        let savedTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let savedOverride = LocalCleanup.modelCallOverrideForTests
        LocalCleanup.setTier(.ai)
        defer {
            LocalCleanup.modelCallOverrideForTests = savedOverride
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let input = "We should we must finish today, and we should check the logs."
        let correct = "We must finish today, and we should check the logs."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text(correct) }
        let outcome = await LocalCleanup.applyWithPath(to: input)
        print("REVIEW modal pipeline: \(outcome.text.debugDescription)")
        XCTAssertTrue(SelfCorrectionFixtures.matches(outcome.text, correct))
    }
}

/// The reviewer's next probes, run before reporting (review of PR #29).
final class SelfCorrectionReviewerSiblingTests: XCTestCase {
    /// Curly quotes are quotes too.
    func testACurlyQuotedNegationIsNotACorrectionLicence() {
        let input = "The example is “Friday, sorry, not Friday, Monday” and we should keep it in the guide."
        XCTAssertNotNil(CleanupGate.rejection(input: input, output: "The example is “Monday” and we should keep it in the guide.", repairHint: false))
    }

    /// With the repair hint licensing the span, only the negation count can
    /// refuse a quoted example's "not": the quote must keep it counted.
    func testAQuotedNegationStaysCountedUnderTheRepairHint() {
        let input = "The example is \"Friday, sorry, not Friday, Monday\" and we keep it."
        XCTAssertEqual(CleanupGate.rejection(input: input, output: "The example is \"Monday\" and we keep it.", repairHint: true),
                       .negationChanged)
    }

    /// A cue inside quotes licenses no deletion beside it (the marker sibling).
    func testAQuotedCueLicensesNothing() {
        let input = "He wrote \"send it to Sam, I mean Priya\" on the board."
        XCTAssertEqual(CleanupGate.rejection(input: input, output: "He wrote \"send it to Priya\" on the board.", repairHint: false),
                       .unlicensedDeletion)
        // The same correction spoken, not quoted, still resolves.
        XCTAssertNil(CleanupGate.rejection(input: "Send it to Sam, I mean Priya, today.", output: "Send it to Priya, today.", repairHint: false))
    }

    /// The cue path shares the re-clean: its paragraphs survive too.
    @MainActor
    func testACueAcrossAPauseKeepsParagraphBreaks() async {
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.off)
        defer {
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let head = "Introduction.\n\nSend it to Bob."
        let next = "Wait, no, Alice.\n\nThanks."
        let result = await Coordinator.assembleSegments([.init(text: head, sealedBy: .pause), .init(text: next, sealedBy: nil)])
        XCTAssertEqual(result, head + " " + next)
    }

    /// A revision pair stays whole, but a cue glued after it cannot grow
    /// the chunk past two of the longest revisable sentences.
    func testARevisionChunkStaysWithinItsBound() {
        let a = "We were planning to send the completed report to the entire team before noon on Thursday."
        let b = "We are planning to send the completed report to the entire team before noon on Thursday."
        let cue = "Actually, no, we are planning to send only the summary to the leads and the full report to everyone else later."
        for chunk in SentenceChunker.chunks(a + " " + b + " " + cue, coalesce: true, glueFragments: true) {
            XCTAssertLessThanOrEqual(chunk.text.split(separator: " ").count, 2 * SentenceRevision.maxWords, chunk.text)
        }
    }
}

/// Second review of PR #29, the next probes: a revision resolved backwards
/// is refused wherever it sits, at every length.
final class SelfCorrectionBackwardsTests: XCTestCase {
    func testABackwardsRevisionIsRefusedMidParagraphAtEveryLength() {
        for stem in ["going to go.", "planning to send it on Thursday.",
                     "planning to send the completed report to the entire team before noon on Thursday."] {
            let earlier = "We were " + stem, latest = "We are " + stem
            let input = earlier + " " + latest + " Please call me."
            XCTAssertEqual(CleanupGate.rejection(input: input, output: earlier + " Please call me.", repairHint: true), .truncation, stem)
            // The right direction still passes.
            XCTAssertNil(CleanupGate.rejection(input: input, output: latest + " Please call me.", repairHint: true), stem)
        }
    }

    /// A quoted cue beside a deleted sentence does not hand it to the cue
    /// rules: the elaboration is still refused.
    func testAQuotedCueBesideASentenceDoesNotLicenseIt() {
        let input = "Write \"actually\". We must test this. We must test this before release."
        XCTAssertEqual(CleanupGate.rejection(input: input, output: "Write \"actually\". We must test this before release.", repairHint: true),
                       .unlicensedDeletion)
    }
}

/// Third review of PR #29, the next probes: a chain of versions is judged
/// step by step, whichever versions a proposal keeps.
final class SelfCorrectionChainTests: XCTestCase {
    private let v1 = "We were going to leave the office.", v2 = "We are going to leave the office.", v3 = "We will leave the office."

    /// The final version is never lost: keeping only an earlier one, or
    /// earlier ones without the last, is refused. Dropping only a middle
    /// version keeps the final one — a partial clean-up, no worse than the
    /// text as spoken — and may pass.
    func testTheFinalVersionOfAChainIsNeverLost() {
        let input = [v1, v2, v3, "Please call Maya."].joined(separator: " ")
        XCTAssertNil(CleanupGate.rejection(input: input, output: v3 + " Please call Maya.", repairHint: true))
        for wrong in [v1, v2, v1 + " " + v2] {
            XCTAssertNotNil(CleanupGate.rejection(input: input, output: wrong + " Please call Maya.", repairHint: true), wrong)
        }
    }

    func testAContrastInsideAChainIsStillRefused() {
        let input = "We were going to go yesterday. We are going to go tomorrow. We will go tomorrow."
        XCTAssertNotNil(CleanupGate.rejection(input: input, output: "We will go tomorrow.", repairHint: true))
    }

    func testThreeDatesMidParagraphKeepTheFinalChoice() {
        let input = "I want to send this on Thursday morning. I want to send this on Friday morning. I want to send this on Monday morning. Thanks."
        XCTAssertNil(CleanupGate.rejection(input: input, output: "I want to send this on Monday morning. Thanks.", repairHint: true))
        XCTAssertNotNil(CleanupGate.rejection(input: input, output: "I want to send this on Thursday morning. Thanks.", repairHint: true))
    }

    func testAChainReachesTheModelInOneCall() {
        let input = [v1, v2, v3, "Please call Maya."].joined(separator: " ")
        XCTAssertEqual(SentenceChunker.split(input, coalesce: true, glueFragments: true), [[v1, v2, v3].joined(separator: " "), "Please call Maya."])
    }
}

/// "Scratch that." is a whole cue: never glued on as a fragment, within a
/// segment or across a pause (third review of PR #29, the Apple trace).
final class SelfCorrectionScratchThatTests: XCTestCase {
    func testScratchThatIsNotAFragment() {
        XCTAssertFalse(SentenceChunker.endsInNonFinalWord("Scratch that."))
        XCTAssertFalse(SentenceChunker.endsInNonFinalWord("We were going to go. Scratch that."))
        XCTAssertTrue(SentenceChunker.endsInNonFinalWord("I think that."))
        let text = "We are going to leave the office. Scratch that. We will leave the office."
        XCTAssertTrue(SentenceChunker.split(text, coalesce: true, glueFragments: true).joined(separator: " ").contains("Scratch that. We will"))
    }

    @MainActor
    func testScratchThatAcrossAPauseKeepsItsPeriod() async {
        let oldTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        LocalCleanup.setTier(.off)
        defer {
            if let oldTier { UserDefaults.standard.set(oldTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        let result = await Coordinator.assembleSegments([.init(text: "We are going to leave. Scratch that.", sealedBy: .pause),
                                                         .init(text: "We will leave the office.", sealedBy: nil)])
        XCTAssertTrue(result.contains("Scratch that."), result)
    }
}

/// Fifth review of PR #29, the next probes: the final version must survive
/// in context, but a correct repair inside it is still allowed.
final class SelfCorrectionFinalInContextTests: XCTestCase {
    private let v1 = "We were going to leave the office."

    func testARepairInsideTheFinalVersionStillPasses() {
        for (final, cleaned) in [("We will will leave the office.", "We will leave the office."),
                                 ("We will l leave the office.", "We will leave the office."),
                                 ("We will we will leave the office.", "We will leave the office.")] {
            XCTAssertNil(CleanupGate.rejection(input: v1 + " " + final, output: cleaned, repairHint: true), final)
        }
    }

    func testTheFinalVersionMustSurviveAsOneRun() {
        let input = v1 + " We will leave the office. Maya will call tomorrow."
        XCTAssertNotNil(CleanupGate.rejection(input: input, output: v1 + " Maya will call tomorrow.", repairHint: true))
        XCTAssertNil(CleanupGate.rejection(input: input, output: "We will leave the office. Maya will call tomorrow.", repairHint: true))
        XCTAssertFalse(CleanupGate.survives(["we", "approve", "the", "refund"], in: ["we", "can", "approve", "the", "refund"]))
    }
}

/// Sixth review of PR #29, the next probes: what a "repair" may remove.
final class SelfCorrectionRepairableTests: XCTestCase {
    /// A doubled content word is content, never a repair ("one one-bedroom").
    func testADoubledContentWordIsNotRepairedAway() {
        XCTAssertEqual(CleanupGate.repaired(["we", "want", "one", "one", "bedroom", "flat"]), ["we", "want", "one", "one", "bedroom", "flat"])
        XCTAssertEqual(CleanupGate.repaired(["we", "will", "will", "leave", "the", "the", "office"]), ["we", "will", "leave", "the", "office"])
        XCTAssertFalse(CleanupGate.survives(["we", "want", "one", "one", "bedroom", "flat"], in: ["we", "want", "one", "bedroom", "flat"]))
    }

    /// The gate's own stutter rule, apart from any revision: a real word that
    /// prefixes the next one is not a stutter it may drop unlicensed.
    func testTheGateDoesNotDropARealWordAsAStutter() {
        XCTAssertEqual(CleanupGate.rejection(input: "We want six sixteen inch pizzas.", output: "We want sixteen inch pizzas.", repairHint: false),
                       .unlicensedDeletion)
        XCTAssertNil(CleanupGate.rejection(input: "That is a c cloud setting.", output: "That is a cloud setting.", repairHint: false))
    }
}

/// Seventh and eighth reviews of PR #29, the next probes: capitals mark an
/// acronym by position, never by spelling.
final class SelfCorrectionAcronymTests: XCTestCase {
    func testOnlyTwoOrMoreCapitalsMarkAnAcronymAndOnlyWhereWritten() {
        let input = "Re rework the C c change before AI review, then pr prepare the PR. Do NOT ship."
        let keys = CleanupGate.caseKeys(input, tokens: CleanupGate.tokens(of: input))
        XCTAssertEqual(keys.filter { $0.hasPrefix("^") }, ["^ai", "^pr"])
        XCTAssertTrue(keys.contains("pr"), "the lowercase fragment keeps its own key")
        XCTAssertTrue(keys.contains("not"), "an all-caps negation is still a negation")
        XCTAssertNil(CleanupGate.rejection(input: "Please re rework the plan.", output: "Please rework the plan.", repairHint: false))
        XCTAssertNil(CleanupGate.rejection(input: "C c change the plan.", output: "Change the plan.", repairHint: false))
        XCTAssertEqual(CleanupGate.rejection(input: "Do NOT ship it.", output: "Do ship it.", repairHint: true), .negationChanged)
    }

    /// The rules pass strips spoken fillers, never an all-caps acronym.
    func testTheRulesPassKeepsAnAllCapsAcronym() {
        XCTAssertEqual(BasicCleanup.clean("Um, we joined the UM team, uh, today."), "We joined the UM team today.")
        XCTAssertFalse(BasicCleanup.hasStrippableFiller("We joined the UM research team."))
        XCTAssertTrue(BasicCleanup.hasStrippableFiller("We um joined."))
    }
}

/// Ninth review of PR #29, the next probes: case marks classify, never
/// identify; asides in capitals are content in the gate as in the rules.
final class SelfCorrectionCaseIdentityTests: XCTestCase {
    func testTheGateNeverLicensesDroppingACapitalAside() {
        XCTAssertNotNil(CleanupGate.rejection(input: "The event names are START, LIKE, STOP today.",
                                              output: "The event names are START, STOP today.", repairHint: false))
        XCTAssertNil(CleanupGate.rejection(input: "I was thinking, like, maybe tomorrow.", output: "I was thinking maybe tomorrow.", repairHint: false))
    }

    func testACapitalFillerIsKeptButALowercaseOneStillGoes() {
        XCTAssertNotNil(CleanupGate.rejection(input: "We joined the UM team.", output: "We joined the team.", repairHint: false))
        XCTAssertNil(CleanupGate.rejection(input: "We um joined the team.", output: "We joined the team.", repairHint: false))
        // Lowercased, "UM" would be stripped as a filler afterwards: a change.
        XCTAssertNotNil(CleanupGate.rejection(input: "We joined the UM team.", output: "We joined the um team.", repairHint: false))
        XCTAssertNil(CleanupGate.rejection(input: "We call the API.", output: "We call the api.", repairHint: false), "a case fix alone is no edit")
    }
}

/// Eleventh review of PR #29, the next probes: the restart's final modal
/// survives in its negated forms too, and an abandoned start may still lose
/// its modal.
final class SelfCorrectionLaterModalTests: XCTestCase {
    func testANegatedFinalModalSurvives() {
        XCTAssertNotNil(CleanupGate.rejection(input: "We will we won't go to the launch.", output: "We will go to the launch.", repairHint: true))
        XCTAssertNil(CleanupGate.rejection(input: "We will we won't go to the launch.", output: "We won't go to the launch.", repairHint: true))
        XCTAssertNotNil(CleanupGate.rejection(input: "I can approve I cannot approve the refund.", output: "I can approve the refund.", repairHint: true))
    }

    func testAnAbandonedStartMayStillLoseItsModal() {
        XCTAssertNil(CleanupGate.rejection(input: "Okay, uh can you send the do we have the report ready to share?",
                                           output: "Okay, do we have the report ready to share?", repairHint: true))
    }
}

/// Fallback review of PR #29, the next probes: every rules path keeps an
/// unresolved correction's cue, and correct proposals still resolve.
final class SelfCorrectionFallbackPathTests: XCTestCase {
    private let input = "Our team has five, I mean, six open roles."

    func testTheRulesPassKeepsTheCue() {
        XCTAssertEqual(BasicCleanup.clean(input), input)
        XCTAssertEqual(BasicCleanup.clean("We should, like, try it, you know, today."), "We should try it today.")
    }

    func testCorrectProposalsStillResolve() {
        XCTAssertNil(CleanupGate.rejection(input: input, output: "Our team has six open roles.", repairHint: false))
        XCTAssertNil(CleanupGate.rejection(input: "Please call Anna, I mean, please email Anna.", output: "Please email Anna.", repairHint: false))
    }

    func testAFailedModelCallAndTheRulesTierKeepTheCue() async throws {
        let previousTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let previousOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = previousOverride
            if let previousTier { UserDefaults.standard.set(previousTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.basic)
        let basic = await LocalCleanup.applyWithPath(to: input).text
        XCTAssertEqual(basic, input)
        guard #available(macOS 26.0, *), AICleanup.isAvailable else { return }
        LocalCleanup.setTier(.ai)
        LocalCleanup.modelCallOverrideForTests = { _, _ in .failed("error") }
        let failed = await LocalCleanup.applyWithPath(to: input).text
        XCTAssertEqual(failed, input)
    }
}
