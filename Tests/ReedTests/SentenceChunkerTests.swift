import XCTest
@testable import Reed

/// Pins the sentence-level cleanup split (2026-08-19): one chunk per
/// sentence — the length the model is reliable at — except corrections,
/// which stay glued to the sentence they correct.
final class SentenceChunkerTests: XCTestCase {
    func testSplitsAtSentenceBoundaries() {
        XCTAssertEqual(
            SentenceChunker.split("Ship it today. Tomorrow we test. Friday we launch."),
            ["Ship it today.", "Tomorrow we test.", "Friday we launch."])
    }

    func testSingleSentencePassesThrough() {
        XCTAssertEqual(SentenceChunker.split("Just one thought here"),
                       ["Just one thought here"])
    }

    func testDecimalsAndDomainsDoNotSplit() {
        XCTAssertEqual(
            SentenceChunker.split("The invoice is £15.50 at 9.30 on w20labs.ai today."),
            ["The invoice is £15.50 at 9.30 on w20labs.ai today."])
    }

    func testCorrectionCueGluesToPredecessor() {
        // The load-bearing case: the resolution needs both sentences.
        XCTAssertEqual(
            SentenceChunker.split("Send the report to Bob. Wait, no, send it to Alice."),
            ["Send the report to Bob. Wait, no, send it to Alice."])
        XCTAssertEqual(
            SentenceChunker.split("Paint it blue. Scratch that, make it green."),
            ["Paint it blue. Scratch that, make it green."])
    }

    func testFillerPrefixedCueStillGlues() {
        XCTAssertEqual(
            SentenceChunker.split("Do it today. Um no, wait, do it tomorrow."),
            ["Do it today. Um no, wait, do it tomorrow."])
    }

    func testTheRealFieldCaseSplitsTheBrokenSentenceOut() {
        // 2026-08-19: the model fixes the last sentence alone, never inside
        // the whole transcript.
        let raw = "Is this sentence is grammatically correct? Um but it didn't correct. "
            + "Um is can I trying to understand why it was not corrected."
        XCTAssertEqual(SentenceChunker.split(raw).count, 3)
    }

    func testQuestionAndEllipsisEndSentences() {
        XCTAssertEqual(
            SentenceChunker.split("Really? I had no idea… That changes things."),
            ["Really?", "I had no idea…", "That changes things."])
    }

    // MARK: - Oversized-chunk resplit (field failure 2026-08-26)

    /// The actual field failure: a 53 s dictation Whisper transcribed with
    /// ZERO punctuation became one 123-word chunk — far outside the model's
    /// working range, so the acceptance nets rejected its output wholesale
    /// and the user got a raw run-on. Unpunctuated run-ons must re-split
    /// into model-sized windows.
    func testUnpunctuatedRunOnResplitsIntoModelSizedWindows() {
        let runOn = "check the result and on the left side where it says needs you "
            + "and I try to play it it plays a random part and tells me that it needs me "
            + "I'm not sure so it looks like there is a correlation issue also the middle "
            + "name was missed for some reason although I clearly stated the middle name "
            + "so something is off with processing the text could you tell me how logic "
            + "is implemented after I speak what happens with the text and when do we "
            + "load the form fields and when do we try to map those to the voice input"
        let chunks = SentenceChunker.split(runOn)
        XCTAssertGreaterThan(chunks.count, 2, "a ~110-word run-on must not stay one chunk")
        for chunk in chunks {
            let words = chunk.split(whereSeparator: \.isWhitespace).count
            XCTAssertLessThanOrEqual(words, 28, "chunk outside the model's range: \(chunk)")
            XCTAssertGreaterThan(words, 4, "orphan tail must glue to its predecessor: \(chunk)")
        }
        // Nothing lost, nothing invented: the pieces re-join to the input.
        XCTAssertEqual(chunks.joined(separator: " "), runOn)
    }

    /// A cut prefers a connective boundary — the sentence break the speaker
    /// implied but the ASR never wrote — over a mid-clause hard cut.
    func testResplitPrefersASoftBreak() {
        let words = Array(repeating: "word", count: 20) + ["also"] + Array(repeating: "tail", count: 10)
        let chunks = SentenceChunker.split(words.joined(separator: " "))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[1].hasPrefix("also "), "the cut must land BEFORE the connective: \(chunks)")
    }

    /// Normal punctuated sentences are already model-sized — untouched.
    func testShortSentencesAreNeverResplit() {
        XCTAssertEqual(
            SentenceChunker.split("Ship it today. Tomorrow we test."),
            ["Ship it today.", "Tomorrow we test."])
    }
    // MARK: - Coalescing (latency step 1, 2026-08-27)

    /// The floor is per call: two short sentences in one call cost one floor.
    func testCoalesceMergesTwoShortSentences() {
        XCTAssertEqual(
            SentenceChunker.split("Ship it today. Tomorrow we test.", coalesce: true),
            ["Ship it today. Tomorrow we test."])
    }

    /// The sentence ceiling: never more than two per call (quality decays on
    /// long input — the reason per-sentence cleaning exists).
    func testCoalesceCapsAtTwoSentences() {
        XCTAssertEqual(
            SentenceChunker.split("One here. Two here. Three here. Four here.", coalesce: true),
            ["One here. Two here.", "Three here. Four here."])
    }

    /// The character ceiling: a pair that would exceed it stays split.
    func testCoalesceRespectsTheCharacterCeiling() {
        let long = String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces) + "."
        XCTAssertEqual(
            SentenceChunker.split("\(long) \(long)", coalesce: true),
            [long, long], "two ~100-char sentences must not become one 200-char call")
    }

    /// Resplit fragments of an unpunctuated run-on carry no terminal mark and
    /// must never be merged back into the oversized chunk resplit removed.
    func testCoalesceLeavesRunOnFragmentsAlone() {
        let runOn = Array(repeating: "word", count: 20) + ["also"] + Array(repeating: "tail", count: 10)
        let text = runOn.joined(separator: " ")
        XCTAssertEqual(SentenceChunker.split(text, coalesce: true), SentenceChunker.split(text))
    }

    /// The long-input A/B regression (2026-08-27): a run-on resplit at "so"
    /// leaves a fragment that INHERITS the sentence's period — merging it
    /// onto the next sentence produced a lowercase-opening chunk, and the
    /// model lowercased every proper noun in it. Fragments never coalesce;
    /// the following whole sentence stays its own call.
    func testCoalesceNeverMergesAResplitFragment() {
        let runOn = "Just a quick update, the deployment finished around eleven last night, "
            + "all tests passed, and the client confirmed they're happy, so we can move on "
            + "to phase two starting Monday."
        let next = "Ship the package to 22 Baker Street, London, and the cost should be around £15.50."
        let chunks = SentenceChunker.split(runOn + " " + next, coalesce: true)
        XCTAssertEqual(chunks.last, next, "the sentence after a resplit run-on must not absorb its fragment: \(chunks)")
        XCTAssertTrue(chunks.contains { $0.hasPrefix("so we can") }, "the fragment survives as its own chunk")
    }

    /// A glued correction counts as one sentence for the cap.
    func testCoalesceTreatsAGluedCorrectionAsOneSentence() {
        XCTAssertEqual(
            SentenceChunker.split("Send it to Bob. Wait, no, Alice. Then call me.", coalesce: true),
            ["Send it to Bob. Wait, no, Alice. Then call me."])
    }

    // MARK: - Pause fragments (cleanup-quality item 2, 2026-08-29)

    func testFragmentEndingInANonFinalWordIsGluedToTheNextSentence() {
        let text = "The onboarding flow still has. That issue where the model download stalls. And if we ship on Friday we're going to. Spend the whole weekend answering emails."
        XCTAssertEqual(SentenceChunker.split(text, glueFragments: true), [
            "The onboarding flow still has that issue where the model download stalls.",
            "And if we ship on Friday we're going to spend the whole weekend answering emails."
        ])
        // "I" and acronyms keep their case across the glue.
        XCTAssertEqual(SentenceChunker.split("Because the. I think so. Ask the. ECS team.", glueFragments: true),
                       ["Because the I think so.", "Ask the ECS team."])
        // Off by default: the split stays per sentence.
        XCTAssertEqual(SentenceChunker.split(text).count, 4)
    }

    func testRealSentenceEndsAreNotGlued() {
        for sentence in ["That's what I think.", "Please do not.", "We should ship it.", "Thank you.", "Look at this.", "Come in.", "It's over.", "Not really.", "Please do.", "Ask them if they'd prefer September second."] {
            XCTAssertFalse(SentenceChunker.endsInNonFinalWord(sentence), sentence)
        }
        for fragment in ["the more I think we should move the.", "still has.", "we're going to.", "add the.", "with and.", "and if we're.", "because they're!", "the problem is."] {
            XCTAssertTrue(SentenceChunker.endsInNonFinalWord(fragment), fragment)
        }
    }

    func testGlueRunsBeforeCoalesceAndRespectsTheResplit() {
        // A glued pair that is still short may coalesce with a third sentence.
        let text = "Add the. Tooltip. Ship it."
        XCTAssertEqual(SentenceChunker.split(text, coalesce: true, glueFragments: true), ["Add the tooltip. Ship it."])
        // Never past the resplit cap: the glued chunk would be cut back into
        // lowercase-opening fragments the model mishandles.
        let long = "We are going to. " + Array(repeating: "word", count: 22).joined(separator: " ") + "."
        XCTAssertEqual(SentenceChunker.split(long, glueFragments: true).count, 2)
    }

    /// Everyday dictations have no pause-fragments: they chunk identically
    /// with the glue on and off.
    ///
    /// **Sanitised regression fixtures, derived from recorded examples.** These
    /// keep the sentence shapes that the chunker actually has to handle — they
    /// were adapted from real dictation, with people, places and amounts
    /// replaced — so they are not invented from nothing and should not be
    /// described as if they were.
    ///
    /// They live here so the property is checked on every run. It used to be
    /// checked only against a gitignored recording corpus, which meant the test
    /// silently skipped wherever that corpus was absent — on CI, on a
    /// contributor's machine, and on any curated export. A check that
    /// disappears with its input is not a check.
    static let everydayDictations = [
        "Just a quick update, the deployment finished around eleven last night.",
        "Can you move the design review to Thursday afternoon and attach the mockups.",
        "The invoice total is three thousand one hundred and sixty two dollars.",
        "I will send the revised timeline to everyone by three o'clock at the latest.",
        "Ship the package to twenty two Baker Street, London.",
        "The short version is that the onboarding flow still stalls on the download.",
        "Let me know if any of this does not work for you.",
        "We should move the date because the onboarding flow is not ready yet.",
    ]

    /// Whether a string carries text worth chunking. Blank is not usable:
    /// spaces and newlines are not sentences, and counting them as input let a
    /// corpus of `[{"verbatim":"   ","clean":"\n\t"}]` satisfy the
    /// "did we check anything?" guard and report a pass. `.whitespaces` alone
    /// is not enough — it does not include newlines, which is exactly what that
    /// input used.
    static func isUsable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The reproduction, kept as a check: these are the values that passed.
    func testBlankTextIsNotUsableInput() {
        XCTAssertFalse(Self.isUsable(""))
        XCTAssertFalse(Self.isUsable("   "), "spaces are not text")
        XCTAssertFalse(Self.isUsable("\n\t"), "newlines and tabs are not text")
        XCTAssertFalse(Self.isUsable(" \n \t\r\n "))
        XCTAssertTrue(Self.isUsable("Ship it Friday."))
        XCTAssertTrue(Self.isUsable("  Ship it Friday.  "), "padding does not make real text unusable")
    }

    func testGlueLeavesEverydayDictationsUntouched() {
        // An empty fixture list would make this pass while checking nothing.
        XCTAssertGreaterThanOrEqual(Self.everydayDictations.count, 5, "the fixture set was emptied")
        for text in Self.everydayDictations {
            XCTAssertTrue(Self.isUsable(text), "blank fixture")
            XCTAssertEqual(SentenceChunker.split(text, coalesce: true, glueFragments: true),
                           SentenceChunker.split(text, coalesce: true, glueFragments: false), text)
        }
    }

    /// The same property against the opt-in recording corpus, when one is
    /// configured. This one may skip: its input is deliberately not in the
    /// tree and must never be committed to make it run.
    func testGlueLeavesTheRecordedCorpusUntouched() throws {
        guard let root = VoiceCorpus.availableRoot else { throw XCTSkip("no voice corpus configured") }
        let path = "\(root)/clips_ref.json"

        // Exactly one thing may skip: the file not being there at all. Anything
        // that IS there and cannot be used is a failure. The earlier version
        // used `try?`, so a clips_ref.json that was a directory, or truncated,
        // or not JSON, reported "no clips_ref.json" and passed — a configured
        // but broken corpus was indistinguishable from an absent one.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw XCTSkip("no clips_ref.json in the voice corpus at \(root)")
        }
        XCTAssertFalse(isDirectory.boolValue, "clips_ref.json is a directory, not a corpus file")
        guard !isDirectory.boolValue else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data)
        let clips = try XCTUnwrap(parsed as? [[String: Any]], "clips_ref.json is not an array of clips")
        XCTAssertFalse(clips.isEmpty, "clips_ref.json holds no clips")

        var checked = 0
        for clip in clips {
            for key in ["verbatim", "clean"] {
                guard let text = clip[key] as? String, Self.isUsable(text) else { continue }
                checked += 1
                XCTAssertEqual(SentenceChunker.split(text, coalesce: true, glueFragments: true),
                               SentenceChunker.split(text, coalesce: true, glueFragments: false), text)
            }
        }
        // A corpus of clips with no usable text would otherwise pass silently.
        XCTAssertGreaterThan(checked, 0, "clips_ref.json has clips but no verbatim/clean text")
    }

    // MARK: - Resplit fragments (finding 5, 2026-08-29)

    func testChunksMarkResplitFragmentsAsContinuations() {
        let long = "we should move the date because " + Array(repeating: "word", count: 40).joined(separator: " ") + "."
        let chunks = SentenceChunker.chunks(long)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertFalse(chunks[0].continuesPrevious)
        XCTAssertTrue(chunks.dropFirst().allSatisfy(\.continuesPrevious))
        XCTAssertEqual(chunks.map(\.text), SentenceChunker.split(long), "the same pieces as split()")
        XCTAssertEqual(SentenceChunker.chunks("Short one. Short two.").map(\.continuesPrevious), [false, false])
    }

    func testJoinFragmentRestoresTheSeam() {
        XCTAssertEqual(LocalCleanup.joinFragment(previous: "We should move the.", next: "Date because the onboarding flow.", restoreLowercase: true),
                       "We should move the date because the onboarding flow.")
        XCTAssertEqual(LocalCleanup.joinFragment(previous: "Ask the team and", next: "I will send the timeline.", restoreLowercase: true),
                       "Ask the team and I will send the timeline.")
        XCTAssertEqual(LocalCleanup.joinFragment(previous: "Push it to", next: "GitHub before Friday.", restoreLowercase: false),
                       "Push it to GitHub before Friday.")
        XCTAssertEqual(LocalCleanup.capitalizingFirst("wednesday give engineering"), "Wednesday give engineering")
    }
}

