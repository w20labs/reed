import XCTest
@testable import Reed

/// Seam verdicts (decision 1, narrowed 2026-09-07): the one shipped rule
/// fires only on a head that opens a subordinate clause and leaves it
/// open; every other pause stays as spoken. Applying a verdict moves a
/// mark and at most one capital, never a word and never a name's capital.
final class SeamRulesTests: XCTestCase {
    func testAClauseHeadThatIsNotClosedTakesAComma() {
        let positives: [(String, String)] = [
            ("If we ship on Friday.", "We lose the weekend."),
            ("While I was there.", "I saw Bob."),
            ("While there is time.", "Let's go."),          // existential there is a subject
            ("Although it works.", "It is slow."),
            ("Whenever you have a minute.", "Call me."),
            ("When we're done.", "Let's ship."),          // a contraction is one verb
            ("If it's fine.", "We go."),
            ("Thanks.\n\nIf the build passes.", "Dana can deploy."),
            ("Thanks. If we ship on Friday.", "We lose the weekend.")   // the head's LAST sentence is the clause
        ]
        for (head, next) in positives {
            XCTAssertEqual(SeamRules.verdict(head: head, next: next), .comma, "\(head) | \(next)")
        }
    }

    /// The negatives the decision named: a conjunction opening the next
    /// piece, a clause after the main one, a legitimate period before
    /// "But" — and the shapes the rule must stay out of.
    func testEveryOtherPauseStaysAsSpoken() {
        let negatives: [(String, String, String)] = [
            ("We need speed.", "And reliability.", "a conjunction opening the next piece is not evidence"),
            ("We delayed the release.", "Because the tests failed.", "a clause after the main one is usually right as it is"),
            ("The plan is fine.", "But the date is not.", "a period before But can be legitimate"),
            ("When did it break?", "It broke yesterday.", "a question"),
            ("When did it break.", "It broke yesterday.", "a question the recognizer left without its mark"),
            ("If it rains, we stay.", "Then we go.", "a clause already closed by its main clause"),
            ("If so.", "Send it.", "too short to trust"),
            ("Whenever.", "Send it.", "one word"),
            ("If we ship on Friday!", "We lose the weekend.", "not a period"),
            ("If we ship on Friday", "We lose the weekend.", "no mark at all: the breath rule's ground"),
            ("If we ship on Friday.", "", "nothing after the pause"),
            ("", "We lose the weekend.", "nothing before it"),
            ("Tell me.", "That intake is hard.", "a plain sentence end"),
            ("We are going to.", "Spend the weekend.", "the breath rule's case, untouched by this one"),
            // Review 2026-09-07: the breath rule keeps precedence; an opener
            // does not prove an open clause.
            ("If we want to.", "Ship on Friday, we need to hurry.", "a head the breath rule joins has the stronger evidence"),
            ("Before long we had a working build.", "The tests passed.", "before as an adverb opens a complete sentence"),
            ("Once we were competitors.", "Now we work together.", "once as an adverb opens a complete sentence"),
            ("After the meeting with Bob.", "We'll decide.", "after is out with the other prepositions"),
            ("Until then we wait.", "Then we go.", "until is out"),
            ("If it ain't broke don't fix it.", "We ship.", "an imperative main clause inside the head"),
            ("When the build passes we deploy it.", "Tests run.", "a second verb: the main clause is inside the head"),
            ("Although it works it is slow.", "We ship.", "a second verb"),
            ("While there is time there is hope.", "Go.", "a second verb"),
            // Review 2026-09-07, round 2: noun subjects and contractions.
            ("If the build passes the release goes out.", "We can celebrate.", "a noun subject's main clause"),
            ("If nobody objects we'll merge.", "Then we rest.", "a contracted main clause"),
            ("While the server restarts users see errors.", "Then it recovers.", "too long to trust the tagger"),
            ("When you were generating images using my key.", "Which model did you use?", "too long to trust the tagger: stays as spoken"),
            ("Unless someone objects.", "We go ahead.", "the tagger finds no verb: no evidence, no comma"),
            // Review 2026-09-07, round 3: an instruction has no subject after the opener.
            ("If in doubt ask me.", "I can explain.", "an elliptical clause and an imperative"),
            ("While waiting read this.", "It explains the issue.", "a participle and an imperative: two verbs, not one group"),
            ("If possible call me.", "I'll be around.", "an adjective, then an imperative"),
            ("If the build passes deploy it.", "Then rest.", "a subject-led clause and an imperative: two groups"),
            ("If you see Bob say hi.", "He's new.", "the tagger misses the second verb: six words is too long to trust it"),
            ("When ready ship it.", "We wait.", "no subject"),
            // Review 2026-09-07, round 4: a verb the tagger misread, and "there" as a place.
            ("If you agree say yes.", "We need an answer.", "the tagger reads 'say' as an interjection: no evidence"),
            ("While there take photos.", "We need them for the report.", "'there' is a place, not a subject")
        ]
        for (head, next, why) in negatives {
            XCTAssertNil(SeamRules.verdict(head: head, next: next), "\(head) | \(next): \(why)")
        }
    }

    func testTheTaggerCountsVerbGroupsNotVerbs() {
        XCTAssertEqual(SeamRules.verbGroups(in: "If we ship on Friday"), 1)
        XCTAssertEqual(SeamRules.verbGroups(in: "When we're done"), 1, "a contracted auxiliary and its participle are one group")
        XCTAssertEqual(SeamRules.verbGroups(in: "If it ain't broke don't fix it"), 2, "an adverb inside a group does not split it")
        XCTAssertEqual(SeamRules.verbGroups(in: "If the build passes the release goes out"), 2)
        XCTAssertEqual(SeamRules.verbGroups(in: "Unless someone objects"), 0)
        XCTAssertEqual(SeamRules.verbGroups(in: "While waiting read this"), 2, "two verbs in a row are two groups unless the first is an auxiliary")
        XCTAssertEqual(SeamRules.verbGroups(in: "If you can ship it"), 1, "a modal carries its verb")
        XCTAssertEqual(SeamRules.verbGroups(in: "If nobody objects we'll merge"), 2)
    }

    func testApplyingACommaKeepsANamesCapitalAndLowersOnlyAClauseOpener() {
        XCTAssertEqual(SeamRules.apply(.comma, head: "If the build passes.", next: "Dana can deploy."), "If the build passes, Dana can deploy.")
        XCTAssertEqual(SeamRules.apply(.comma, head: "If we ship on Friday.", next: "We lose the weekend."), "If we ship on Friday, we lose the weekend.")
        XCTAssertEqual(SeamRules.apply(.comma, head: "Whenever you have a minute.", next: "Call me."), "Whenever you have a minute, Call me.", "an imperative verb may be a name for all the rule knows: the capital stays")
        XCTAssertEqual(SeamRules.apply(.comma, head: "If the role is vacant.", next: "Will is available."), "If the role is vacant, Will is available.", "review 2026-09-07: a modal that is a name is not lowered")
        // The allowlist against the given names that double as function words.
        for name in ["will", "may", "bill", "mark", "sue", "art", "grant", "pat", "jack", "ray", "don", "bob", "june", "april", "hope", "chase"] {
            XCTAssertFalse(SeamRules.loweredOpeners.contains(name), name)
        }
        XCTAssertEqual(SeamRules.apply(.comma, head: "Fine.", next: "I'll go."), "Fine, I'll go.")
        XCTAssertEqual(SeamRules.apply(.comma, head: "When you were generating images.", next: "Which model did you use?"), "When you were generating images, which model did you use?", "apply is a caller's; the rule itself no longer fires on this head")
        XCTAssertEqual(SeamRules.apply(.comma, head: "Already a comma,", next: "Then this."), "Already a comma, then this.")
        XCTAssertEqual(SeamRules.loweringClauseOpener("Dana can deploy"), "Dana can deploy")
        XCTAssertEqual(SeamRules.loweringClauseOpener("It's fine"), "it's fine")
        XCTAssertEqual(SeamRules.loweringClauseOpener("Don’t wait"), "don’t wait")
        // Round 2: an acronym's case is evidence.
        XCTAssertEqual(SeamRules.apply(.comma, head: "If the tests pass.", next: "IT can deploy."), "If the tests pass, IT can deploy.")
        XCTAssertEqual(SeamRules.loweringClauseOpener("WHO said so"), "WHO said so")
        XCTAssertEqual(SeamRules.loweringClauseOpener("It's fine"), "it's fine")
    }

    func testTheOtherVerdictsApplyAndParagraphsSurvive() {
        XCTAssertEqual(SeamRules.apply(.nothing, head: "We are going to.", next: "Spend it."), "We are going to spend it.")
        XCTAssertEqual(SeamRules.apply(.period, head: "No mark at the end", next: "next one."), "No mark at the end. Next one.")
        XCTAssertEqual(SeamRules.apply(.period, head: "He said \"go.\"", next: "So we went."), "He said \"go.\" So we went.", "a closer after the mark still ends the sentence")
        XCTAssertEqual(SeamRules.apply(.comma, head: "First paragraph.\n\nIf we ship on Friday.", next: "We lose the weekend.\n\nLast paragraph."),
                       "First paragraph.\n\nIf we ship on Friday, we lose the weekend.\n\nLast paragraph.")
        XCTAssertEqual(SeamRules.apply(.nothing, head: "A.\nWe are going to.", next: "Spend it.\nB."), "A.\nWe are going to spend it.\nB.")
    }

    func testNoVerdictCanBeAppliedWhereItWouldLoseOrChangeAWord() {
        XCTAssertNil(SeamRules.apply(.comma, head: "", next: "Hello."))
        XCTAssertNil(SeamRules.apply(.nothing, head: "Hello.", next: ""))
        let head = "Do not do it.", next = "Do it now."
        for mark in SeamMark.allCases {
            guard let joined = SeamRules.apply(mark, head: head, next: next) else { XCTFail("\(mark) refused"); continue }
            XCTAssertEqual(Self.words(joined), Self.words(head + " " + next), "\(mark)")
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}
