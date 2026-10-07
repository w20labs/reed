import XCTest
@testable import Reed

/// Pins the word-alignment gate (2026-08-19). Every rejection case here is a
/// real model output from the benches — the gate exists because each one
/// happened.
final class CleanupGateTests: XCTestCase {

    // MARK: - Legitimate edits pass

    func testPunctuationAndCapsOnlyPasses() {
        XCTAssertTrue(CleanupGate.accepts(
            input: "wait what no i said the meeting is at noon not midnight",
            output: "Wait, what? No, I said the meeting is at noon, not midnight.",
            repairHint: false))
    }

    func testFillerDeletionPasses() {
        XCTAssertTrue(CleanupGate.accepts(
            input: "So yeah, I was thinking, you know, maybe we should, uh, grab coffee.",
            output: "So yeah, I was thinking, you know, maybe we should grab coffee.",
            repairHint: false))
    }

    func testStutterAndFunctionRepeatPass() {
        XCTAssertTrue(CleanupGate.accepts(
            input: "I pushed the the fix and that would be a p p pretty big change.",
            output: "I pushed the fix and that would be a pretty big change.",
            repairHint: true))
        XCTAssertTrue(CleanupGate.accepts(
            input: "We pay attention on c uh uh cloud mode.",
            output: "We pay attention on cloud mode.",
            repairHint: true))
        XCTAssertTrue(CleanupGate.accepts(
            input: "Or it's going to be a huge re re rework.",
            output: "Or it's going to be a huge rework.",
            repairHint: true))
    }

    func testMarkedStatementCorrectionPasses() {
        // Interior deletion licensed by the marker "sorry".
        XCTAssertTrue(CleanupGate.accepts(
            input: "The demo is at ten, sorry, eleven thirty.",
            output: "The demo is at eleven thirty.",
            repairHint: false))
    }

    func testCrossSentenceCorrectionPasses() {
        XCTAssertTrue(CleanupGate.accepts(
            input: "Send the report to Bob. Wait, no, send it to Alice.",
            output: "Send the report to Alice.",
            repairHint: false))
    }

    // MARK: - Observed failures reject

    func testHallucinatedWordRejects() {
        // Bench 2026-08-19: "is can I trying" became "I can't understand".
        XCTAssertFalse(CleanupGate.accepts(
            input: "Um is can I trying to understand why it was not corrected.",
            output: "I can't understand why it was not corrected.",
            repairHint: true))
    }

    func testParaphraseRejects() {
        // Battery 2026-08-14: "pursuance" became "pursuit".
        XCTAssertFalse(CleanupGate.accepts(
            input: "in pursuance of your duties",
            output: "in pursuit of your duties",
            repairHint: false))
    }

    func testLostNegationRejects() {
        XCTAssertFalse(CleanupGate.accepts(
            input: "Please do not merge this before the review.",
            output: "Please do merge this before the review.",
            repairHint: true))
    }

    func testWrongOptionSuffixDeletionRejects() {
        // Bench 2026-08-19: kept the abandoned side of the correction.
        XCTAssertFalse(CleanupGate.accepts(
            input: "Move it to the left. Sorry, right.",
            output: "Move it to the left.",
            repairHint: false))
    }

    func testNearRepeatFunctionWordPasses() {
        // Field 2026-08-19: the gate rejected the model's correct fix of the
        // non-adjacent doubled "is".
        XCTAssertTrue(CleanupGate.accepts(
            input: "Is this sentence is grammatically correct?",
            output: "Is this sentence grammatically correct?",
            repairHint: false))
        // But a deleted content word near its duplicate still rejects.
        XCTAssertFalse(CleanupGate.accepts(
            input: "The tests pass and the tests matter.",
            output: "The tests pass and the matter.",
            repairHint: false))
    }

    func testProtectedTokensMustSurviveByteIdentical() {
        // Spec §6 (2026-08-19): the model must not quietly reformat what the
        // vocabulary formatter built — alignment can't see "I-485" → "I 485".
        XCTAssertFalse(CleanupGate.accepts(
            input: "File Form I-485 by Friday.",
            output: "File Form I 485 by Friday.",
            repairHint: false))
        XCTAssertFalse(CleanupGate.accepts(
            input: "Visit w20labs.ai for details.",
            output: "Visit w20labs for details.",
            repairHint: false))
        XCTAssertTrue(CleanupGate.accepts(
            input: "email jane@example.com at 3:30 PM about the $15.50 invoice",
            output: "Email jane@example.com at 3:30 PM about the $15.50 invoice.",
            repairHint: false))
    }

    func testCorrectionMayDropTheAbandonedProtectedToken() {
        // Field 2026-10-06: the model's correct fix was refused because the
        // abandoned time is a protected token. Deleting it whole inside a
        // licensed correction or restart is not a reformat.
        let accepted: [(String, String)] = [
            ("Let's meet at 7:00 PM. No, no, actually, let's meet on 5:00 PM, at 5:00 PM.", "Let's meet at 5:00 PM."),
            ("Let's meet at 7:00 PM. Scratch that, let's meet at 5:00 PM.", "Let's meet at 5:00 PM."),
            ("Send it to bob@example.com. Sorry, I mean alice@example.com.", "Send it to alice@example.com."),
            ("File the I-485 file the I-130 today.", "File the I-130 today.")
        ]
        for (input, output) in accepted {
            let verdict = CleanupGate.verdict(input: input, output: output, repairHint: false)
            XCTAssertNil(verdict.rejection, input)
            XCTAssertEqual(verdict.protectedMissing, [], input)
        }
    }

    func testProtectedTokenLostOutsideALicensedDeletionStillRejects() {
        let rejected: [(String, String)] = [
            // No correction marker: the time just vanished.
            ("Let's meet at 7:00 PM and then lunch.", "Let's meet and then lunch."),
            // Wrong option kept: the deletion reaches the end, unlicensed.
            ("Meet at 7:00 PM. Sorry, 5:00 PM.", "Meet at 7:00 PM."),
            // The kept option reformatted beside a licensed deletion.
            ("Send it to bob@example.com. Sorry, I mean alice@example.com.", "Send it to alice example com."),
            // The abandoned option reformatted, not deleted.
            ("Meet at 7:00 PM. Scratch that, at 5:00 PM.", "Meet at 7 00 PM, at 5:00 PM.")
        ]
        for (input, output) in rejected {
            XCTAssertEqual(CleanupGate.rejection(input: input, output: output, repairHint: false), .protectedToken, input)
        }
    }

    func testDroppingTheCorrectionAtTheEndRejects() {
        // Field 2026-10-06: "…seven pm. Sorry, five pm." → "…seven pm." kept
        // the wrong option. The deletion "sorry five pm" reached the end; the
        // alignment slid its window onto "pm sorry five", whose first word is
        // trivially "re-spoken" next, so the restart licence passed it.
        let rejected: [(String, String)] = [
            ("Meet at seven pm. Sorry, five pm.", "Meet at seven pm."),
            ("Meet at 7:00 PM sorry, 5:00 PM.", "Meet at 7:00 PM."),
            ("Send it to Bob tomorrow. No, Alice tomorrow.", "Send it to Bob tomorrow."),
            // A trailing marker is not a cue — nothing follows it.
            ("Do it. No.", "Do it."),
            ("Ship it, no, no.", "Ship it.")
        ]
        for (input, output) in rejected {
            XCTAssertNotNil(CleanupGate.rejection(input: input, output: output, repairHint: false), input)
        }
        let accepted: [(String, String)] = [
            ("Meet at seven pm. Sorry, five pm.", "Meet at five pm."),
            ("Ship it on Monday on Monday.", "Ship it on Monday."),
            ("I want to go I want to go.", "I want to go."),
            ("Can you tell me tell me", "Can you tell me"),
            ("Thanks for the help, um.", "Thanks for the help.")
        ]
        for (input, output) in accepted {
            XCTAssertNil(CleanupGate.rejection(input: input, output: output, repairHint: false), input)
        }
    }

    func testIntroducedNewlineRejects() {
        // 2026-08-25: a model-invented line break becomes an Enter keystroke
        // wherever the text lands; word alignment is whitespace-blind.
        XCTAssertFalse(CleanupGate.accepts(
            input: "list the files then remove the temp folder",
            output: "list the files\nthen remove the temp folder",
            repairHint: false))
        // Newlines already present in the input may survive.
        XCTAssertTrue(CleanupGate.accepts(
            input: "first line\nsecond line",
            output: "First line\nsecond line.",
            repairHint: false))
    }

    func testStructuralSpanWithHintPasses() {
        // Repair hint licenses one interior structural span (the restart).
        XCTAssertTrue(CleanupGate.accepts(
            input: "Okay, uh can you send the do we have the report ready to share?",
            output: "Okay, do we have the report ready to share?",
            repairHint: true))
    }

    // MARK: - Licenses from the gate bench (2026-08-29)

    func testPhraseRestartsPass() {
        for (input, output) in [
            ("Ship it Friday and tell them tell the team.", "Ship it Friday and tell the team."),
            ("I want to I want to go over the numbers first.", "I want to go over the numbers first."),
            ("Tell Dana tell Dana to call me back.", "Tell Dana to call me back."),
            ("So the plan the plan is to ship on Monday.", "So the plan is to ship on Monday."),
            ("We should probably we should ship on Friday.", "We should probably ship on Friday.")
        ] {
            XCTAssertNil(CleanupGate.rejection(input: input, output: output, repairHint: false), input)
        }
    }

    func testEmphasisRepeatStillRejects() {
        XCTAssertEqual(CleanupGate.rejection(input: "It was really really bad.", output: "It was really bad.", repairHint: true), .emphasisRepeat)
    }

    func testLosingTheOnlyModalStillRejects() {
        XCTAssertEqual(CleanupGate.rejection(input: "We should ship on Friday.", output: "We ship on Friday.", repairHint: true), .negationChanged)
        XCTAssertEqual(CleanupGate.rejection(input: "Do not do it.", output: "Do it.", repairHint: true), .negationChanged)
    }

    func testLeadingDiscourseOpenerMayGo() {
        XCTAssertNil(CleanupGate.rejection(input: "so we'll probably need to move it to a different date", output: "We'll probably need to move it to a different date.", repairHint: false))
        XCTAssertNil(CleanupGate.rejection(input: "okay so send it to the team", output: "Send it to the team.", repairHint: false))
        // Not a licence for content at the start — nor for an article: a
        // chunk that opens "the counter…" is a resplit fragment (gate bench #32).
        XCTAssertEqual(CleanupGate.rejection(input: "Please send it to the team.", output: "Send it to the team.", repairHint: false), .unlicensedDeletion)
        XCTAssertEqual(CleanupGate.rejection(input: "the counter, work began immediately", output: "counter, work began immediately", repairHint: false), .unlicensedDeletion)
    }

    func testCommaDelimitedAsidesAreFillers() {
        XCTAssertNil(CleanupGate.rejection(
            input: "Um, so yeah, I was thinking, you know, maybe we should, uh, grab coffee sometime next week and, like, catch up on the project.",
            output: "So yeah, I was thinking maybe we should grab coffee sometime next week and catch up on the project.",
            repairHint: false))
        // "like" as a verb is content.
        XCTAssertEqual(CleanupGate.rejection(input: "I like the new design a lot.", output: "I the new design a lot.", repairHint: false), .unlicensedDeletion)
    }

    func testRejectionReasonsAreNamed() {
        XCTAssertEqual(CleanupGate.rejection(input: "Move it to the left. Sorry, right.", output: "Move it to the left.", repairHint: false), .truncation)
        XCTAssertEqual(CleanupGate.rejection(input: "send the file to bob", output: "send the report to bob", repairHint: false), .addedWord)
    }

    // MARK: - Round 2 (2026-08-29, the user's two-minute reads)

    func testSixWordFalseStartIsARestart() {
        XCTAssertNil(CleanupGate.rejection(
            input: "First can someone and Dana and Fel can someone add Dana and Felix to the launch channel.",
            output: "First, can someone add Dana and Felix to the launch channel.", repairHint: false))
    }

    func testShortFunctionWordRestartPassesLongOneStillRejects() {
        XCTAssertNil(CleanupGate.rejection(
            input: "Nadia reproduced it twice on her on the office Wi-Fi.",
            output: "Nadia reproduced it twice on the office Wi-Fi.", repairHint: false))
        // The five-word span followed by a coincidental "the" stays unlicensed.
        XCTAssertEqual(CleanupGate.rejection(
            input: "The deploy finished early and the tests are green.",
            output: "The tests are green.", repairHint: false), .unlicensedDeletion)
    }

    func testRepeatedNegationCollapsesButALostOneStillRejects() {
        XCTAssertNil(CleanupGate.rejection(
            input: "And support hasn't hasn't been trained on the new settings pane yet.",
            output: "And support hasn't been trained on the new settings pane yet.", repairHint: false))
        XCTAssertEqual(CleanupGate.rejection(
            input: "And support hasn't been trained yet.",
            output: "And support been trained yet.", repairHint: true), .negationChanged)
    }

    func testSeveralLicensedStumblesInOneChunkPass() {
        // Four fixes at once, under the repair hint (structural detection fired).
        XCTAssertNil(CleanupGate.rejection(
            input: "One On the budget side the invoice came in on her on the estimate and the the demo video is ready on the ready to go.",
            output: "On the budget side the invoice came in on the estimate and the demo video is ready to go.", repairHint: true))
        // Still one unlicensed span → rejected, however many licensed ones sit beside it.
        XCTAssertEqual(CleanupGate.rejection(
            input: "The the demo video is ready and the client confirmed they are happy with the deployment.",
            output: "The demo video is ready and they are happy with the deployment.", repairHint: false), .unlicensedDeletion)
    }

    func testOverEditingStillRejects() {
        // Round 2 fixture 17: the model lost "to go" and "not day after".
        XCTAssertNotNil(CleanupGate.rejection(
            input: "The demo video should be ready on the ready to go on on the day not day after.",
            output: "The demo video should be ready on the day.", repairHint: true))
    }
}

