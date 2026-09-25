import XCTest
@testable import Reed

/// P16: assembly reports what it did at every seam, and reporting changes
/// nothing about the text.
final class AssemblyJoinDecisionTests: XCTestCase {
    private typealias Piece = Coordinator.Piece

    private func assemble(_ pieces: [Piece], verdicts: [Int: SeamMark] = [:]) async -> (String, [Int: ReviewRecord.JoinDecision]) {
        var seen: [Int: ReviewRecord.JoinDecision] = [:]
        let text = await Coordinator.assembleSegments(pieces, verdicts: verdicts) { seen[$0] = $1 }
        let silent = await Coordinator.assembleSegments(pieces, verdicts: verdicts)
        XCTAssertEqual(text, silent, "reporting must not change the text")
        return (text, seen)
    }

    // MARK: - Seam verdicts (decision 1, 2026-09-07)

    func testAVerdictDecidesAPauseSeamAheadOfTheRules() async {
        let pieces = [Piece(text: "If we ship on Friday.", sealedBy: .pause), Piece(text: "We lose the weekend.", sealedBy: nil)]
        let (comma, seenComma) = await assemble(pieces, verdicts: [1: .comma])
        XCTAssertEqual(comma, "If we ship on Friday, we lose the weekend.")
        XCTAssertEqual(seenComma, [1: .seamComma])
        let (nothing, seenNothing) = await assemble(pieces, verdicts: [1: .nothing])
        XCTAssertEqual(nothing, "If we ship on Friday we lose the weekend.")
        XCTAssertEqual(seenNothing, [1: .seamNothing])
        let (period, seenPeriod) = await assemble(pieces, verdicts: [1: .period])
        XCTAssertEqual(period, "If we ship on Friday. We lose the weekend.")
        XCTAssertEqual(seenPeriod, [1: .seamPeriod])
        // The breath rule would glue this; the model's period wins over it.
        let breath = [Piece(text: "We are going to.", sealedBy: .pause), Piece(text: "Spend the weekend.", sealedBy: nil)]
        let (kept, seenKept) = await assemble(breath, verdicts: [1: .period])
        XCTAssertEqual(kept, "We are going to. Spend the weekend.")
        XCTAssertEqual(seenKept, [1: .seamPeriod])
        let plain = [Piece(text: "Tell me.", sealedBy: .pause), Piece(text: "That intake is hard.", sealedBy: nil)]
        let (unchanged, seenUnchanged) = await assemble(plain)
        XCTAssertEqual(unchanged, "Tell me. That intake is hard.", "no verdict and no rule: the pause as before")
        XCTAssertEqual(seenUnchanged, [1: .sentenceEnd])
    }

    /// The one shipped rule: a head that opens a subordinate clause and
    /// does not close it takes a comma — from the rules, with no verdict
    /// injected — and the kill switch leaves the pause as before.
    /// Review 2026-09-07: a head the breath rule joins is joined, whatever
    /// its opener — through assembly, where the precedence lives.
    func testTheBreathRuleKeepsPrecedenceOverTheClauseRule() async {
        let key = FeatureFlags.overrideKey(for: SeamRules.flag)
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(true, forKey: key)
        let (text, seen) = await assemble([Piece(text: "If we want to.", sealedBy: .pause), Piece(text: "Ship on Friday, we need to hurry.", sealedBy: nil)])
        XCTAssertEqual(text, "If we want to ship on Friday, we need to hurry.")
        XCTAssertEqual(seen, [1: .gluedBreath])
    }

    /// Default OFF (review 2026-09-07): until the reviewed corpus shows the
    /// rule corrects more seams than it breaks, a pause stays as before.
    func testAClauseHeadTakesACommaFromTheRulesOnlyWhenTheFlagIsOn() async {
        let pieces = [Piece(text: "If we ship on Friday.", sealedBy: .pause), Piece(text: "We lose the weekend.", sealedBy: nil)]
        let key = FeatureFlags.overrideKey(for: SeamRules.flag)
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(SeamRules.flagDefault)
        let (off, seenOff) = await assemble(pieces)
        XCTAssertEqual(off, "If we ship on Friday. We lose the weekend.", "default off: the pause as before")
        XCTAssertEqual(seenOff, [1: .sentenceEnd])
        UserDefaults.standard.set(true, forKey: key)
        let (text, seen) = await assemble(pieces)
        XCTAssertEqual(text, "If we ship on Friday, we lose the weekend.")
        XCTAssertEqual(seen, [1: .seamComma])
        UserDefaults.standard.removeObject(forKey: key)
        let (injected, seenInjected) = await assemble(pieces, verdicts: [1: .comma])
        XCTAssertEqual(injected, "If we ship on Friday, we lose the weekend.", "an injected verdict is a caller's, not the rules'")
        XCTAssertEqual(seenInjected, [1: .seamComma])
    }

    func testAVerdictNeverOverridesACapCutARestartOrACorrectionCue() async {
        let cap = [Piece(text: "the quick brown", sealedBy: .cap), Piece(text: "brown fox jumps", sealedBy: nil)]
        let (capText, capSeen) = await assemble(cap, verdicts: [1: .period])
        XCTAssertEqual(capText, "the quick brown fox jumps")
        XCTAssertEqual(capSeen, [1: .capSeam])
        let restart = [Piece(text: "Hi my name is.", sealedBy: .pause), Piece(text: "My name is Aram.", sealedBy: nil)]
        let (restartText, restartSeen) = await assemble(restart, verdicts: [1: .comma])
        XCTAssertEqual(restartText, "Hi my name is Aram.")
        XCTAssertEqual(restartSeen, [1: .restartCollapsed])
        let cue = [Piece(text: "Ask Bob.", sealedBy: .pause), Piece(text: "Wait, no, Alice.", sealedBy: nil)]
        let (_, cueSeen) = await assemble(cue, verdicts: [1: .comma])
        XCTAssertEqual(cueSeen, [1: .recleanedAcrossCue], "a spoken correction is re-cleaned, not punctuated")
        let empty = [Piece(text: "Only one.", sealedBy: .pause), Piece(text: "", sealedBy: nil)]
        let (emptyText, emptySeen) = await assemble(empty, verdicts: [1: .comma])
        XCTAssertEqual(emptyText, "Only one.")
        XCTAssertEqual(emptySeen, [:])
    }

    func testAVerdictAtOneSeamLeavesTheOthersToTheRules() async {
        let pieces = [Piece(text: "Tell me.", sealedBy: .pause), Piece(text: "That intake is hard.", sealedBy: .pause),
                      Piece(text: "We are going to.", sealedBy: .pause), Piece(text: "Spend the weekend.", sealedBy: nil)]
        let (text, seen) = await assemble(pieces, verdicts: [1: .comma])
        XCTAssertEqual(text, "Tell me, that intake is hard. We are going to spend the weekend.")
        XCTAssertEqual(seen, [1: .seamComma, 2: .sentenceEnd, 3: .gluedBreath])
    }

    func testAPauseAfterAFullSentenceIsASentenceEnd() async {
        let (text, seen) = await assemble([Piece(text: "Tell me.", sealedBy: .pause), Piece(text: "That intake is hard.", sealedBy: nil)])
        XCTAssertEqual(text, "Tell me. That intake is hard.")
        XCTAssertEqual(seen, [1: .sentenceEnd])
    }

    func testAPauseAfterABreathWordIsGlued() async {
        let (text, seen) = await assemble([Piece(text: "We are going to.", sealedBy: .pause), Piece(text: "Spend the weekend.", sealedBy: nil)])
        XCTAssertEqual(text, "We are going to spend the weekend.")
        XCTAssertEqual(seen, [1: .gluedBreath])
    }

    func testACapCutIsASeamAndAFullyDuplicatedPieceIsAbsorbed() async {
        let (_, seam) = await assemble([Piece(text: "the quick brown", sealedBy: .cap), Piece(text: "brown fox jumps", sealedBy: nil)])
        XCTAssertEqual(seam, [1: .capSeam])
        let (text, absorbed) = await assemble([Piece(text: "the quick brown fox", sealedBy: .cap), Piece(text: "brown fox", sealedBy: nil)])
        XCTAssertEqual(text, "the quick brown fox")
        XCTAssertEqual(absorbed, [1: .absorbed])
    }

    func testTheFirstPieceAndEmptyPiecesReportNothing() async {
        let (_, seen) = await assemble([Piece(text: "Only one.", sealedBy: .pause), Piece(text: "", sealedBy: nil)])
        XCTAssertEqual(seen, [:])
    }

    /// Decision 2 (2026-09-04): a restart split across a pause is collapsed
    /// at the seam under the shared licence; emphasis and chains are not.
    func testARestartAcrossAPauseIsCollapsed() async {
        let (text, seen) = await assemble([Piece(text: "Hi my name is.", sealedBy: .pause), Piece(text: "My name is Aram.", sealedBy: nil)])
        XCTAssertEqual(text, "Hi my name is Aram.")
        XCTAssertEqual(seen, [1: .restartCollapsed])
        let (whole, wholeSeen) = await assemble([Piece(text: "My name is.", sealedBy: .pause), Piece(text: "My name is Aram.", sealedBy: nil)])
        XCTAssertEqual(whole, "My name is Aram.", "the whole head was the abandoned start: the next piece keeps its capital")
        XCTAssertEqual(wholeSeen, [1: .restartCollapsed])
    }

    func testAProperNameKeepsItsCapitalAcrossTheSeamAndANegationIsNeverLost() async {
        let (name, seen) = await assemble([Piece(text: "Please ask Dana Connor.", sealedBy: .pause), Piece(text: "Dana Connor to join.", sealedBy: nil)])
        XCTAssertEqual(name, "Please ask Dana Connor to join.")
        XCTAssertEqual(seen, [1: .restartCollapsed])
        let (neg, negSeen) = await assemble([Piece(text: "Do not do it.", sealedBy: .pause), Piece(text: "Do not do it now.", sealedBy: nil)])
        XCTAssertEqual(neg, "Do not do it. Do not do it now.", "the gate refused the collapse: two sentences stay")
        XCTAssertEqual(negSeen, [1: .sentenceEnd])
    }

    func testLongerEmphasisAndEarlierSentencesAreNotRestartsAtTheSeam() async {
        let (emph, seen) = await assemble([Piece(text: "It was really really.", sealedBy: .pause), Piece(text: "Really really bad.", sealedBy: nil)])
        XCTAssertEqual(emph, "It was really really. Really really bad.")
        XCTAssertEqual(seen, [1: .sentenceEnd])
        let (earlier, earlierSeen) = await assemble([Piece(text: "I said yes. Tell me.", sealedBy: .pause), Piece(text: "Yes tell me more.", sealedBy: nil)])
        XCTAssertEqual(earlier, "I said yes. Tell me. Yes tell me more.")
        XCTAssertEqual(earlierSeen, [1: .sentenceEnd])
        let (para, paraSeen) = await assemble([Piece(text: "First.\n\nHi my name is.", sealedBy: .pause), Piece(text: "My name is Aram.\n\nLast.", sealedBy: nil)])
        XCTAssertEqual(para, "First.\n\nHi my name is Aram.\n\nLast.")
        XCTAssertEqual(paraSeen, [1: .restartCollapsed])
    }

    func testTheKeptCopyMustBeOnePhraseAtTheSeamAndAQuoteSurvives() async {
        let (text, seen) = await assemble([Piece(text: "We need more time.", sealedBy: .pause), Piece(text: "More. Time is running out.", sealedBy: nil)])
        XCTAssertEqual(text, "We need more time. More. Time is running out.")
        XCTAssertEqual(seen, [1: .sentenceEnd])
        let (quoted, quotedSeen) = await assemble([Piece(text: "He said \"my name is.", sealedBy: .pause), Piece(text: "My name is Aram.\"", sealedBy: nil)])
        XCTAssertEqual(quoted, "He said \"my name is Aram.\"")
        XCTAssertEqual(quotedSeen, [1: .restartCollapsed])
        let (inner, innerSeen) = await assemble([Piece(text: "He said \"go on\" and.", sealedBy: .pause), Piece(text: "Go on and finish it.", sealedBy: nil)])
        XCTAssertEqual(inner, "He said \"go on\" and go on and finish it.", "a closer inside the abandoned span: no collapse, the breath is glued")
        XCTAssertEqual(innerSeen, [1: .gluedBreath])
        let (quote, quoteSeen) = await assemble([Piece(text: "Please say.", sealedBy: .pause), Piece(text: "\"Please say hello\" twice.", sealedBy: nil)])
        XCTAssertEqual(quote, "Please say. \"Please say hello\" twice.", "the kept copy opens a quotation: not a restart")
        XCTAssertEqual(quoteSeen, [1: .sentenceEnd])
    }

    func testEmphasisAndChainsAcrossAPauseAreNotRestarts() async {
        let (text, seen) = await assemble([Piece(text: "It was really.", sealedBy: .pause), Piece(text: "Really bad.", sealedBy: nil)])
        XCTAssertEqual(text, "It was really. Really bad.")
        XCTAssertEqual(seen, [1: .sentenceEnd])
        let (chain, chainSeen) = await assemble([Piece(text: "We tried again and.", sealedBy: .pause), Piece(text: "Again and again.", sealedBy: nil)])
        XCTAssertEqual(chain, "We tried again and again and again.", "a chain: glued as a breath, nothing dropped")
        XCTAssertEqual(chainSeen, [1: .gluedBreath])
    }
}
