import XCTest
@testable import Reed

/// Pins that leaked model packaging (chatty preamble + delimiters) is stripped,
/// while ordinary dictated speech that happens to contain "sure", "okay", or a
/// colon is left completely intact.
final class CleanupSanitizerTests: XCTestCase {
    // MARK: strips packaging

    func testStripsReportedPreambleAndDelimiters() {
        XCTAssertEqual(
            CleanupSanitizer.strip("Sure, I can help with that. Here's the cleaned text: «Hello world.»"),
            "Hello world.")
    }

    func testStripsDoubleAngleDelimiters() {
        XCTAssertEqual(
            CleanupSanitizer.strip("Here's the cleaned text: <<Buy milk and eggs.>>"),
            "Buy milk and eggs.")
    }

    func testStripsTaskMetaPreambleWithoutDelimiters() {
        XCTAssertEqual(
            CleanupSanitizer.strip("Here is the polished version: The meeting is at three."),
            "The meeting is at three.")
    }

    func testStripsLeadingFillerBeforePreamble() {
        // Reported leak: a "Sure," interjection before the clean-verb preamble,
        // with no delimiter, slipped past Rule 2's anchor.
        XCTAssertEqual(
            CleanupSanitizer.strip("Sure, here is the cleaned text:\n\nYes, create a local only PR and then we can merge it."),
            "Yes, create a local only PR and then we can merge it.")
    }

    func testStripsOkayBangPreamble() {
        XCTAssertEqual(
            CleanupSanitizer.strip("Okay! Here's the cleaned version: Buy milk and eggs."),
            "Buy milk and eggs.")
    }

    func testStripsDashSeparatedFillerPreamble() {
        XCTAssertEqual(
            CleanupSanitizer.strip("Sure — here's the cleaned text: Hello world."),
            "Hello world.")
    }

    func testStripsUnpunctuatedFillerPreamble() {
        XCTAssertEqual(
            CleanupSanitizer.strip("Sure here is the cleaned text: Hello world."),
            "Hello world.")
    }

    func testUnwrapsWholeStringQuotes() {
        XCTAssertEqual(CleanupSanitizer.strip("\"Just the text.\""), "Just the text.")
    }

    func testUnwrapsCodeFence() {
        XCTAssertEqual(CleanupSanitizer.strip("```\nHello there.\n```"), "Hello there.")
    }

    func testUnwrapsEchoedTranscriptTags() {
        XCTAssertEqual(
            CleanupSanitizer.strip("<transcript>\nThe meeting is at noon.\n</transcript>"),
            "The meeting is at noon.")
    }

    // MARK: leaves real speech alone

    func testKeepsDictatedPlanWithColon() {
        // "okay" + "here's" + a colon must NOT be treated as a preamble.
        let s = "Okay so here's the plan: buy milk, then call Sam."
        XCTAssertEqual(CleanupSanitizer.strip(s), s)
    }

    func testKeepsSentenceStartingWithSure() {
        let s = "Sure, I'll be there by five."
        XCTAssertEqual(CleanupSanitizer.strip(s), s)
    }

    func testKeepsInteriorQuotesAndColons() {
        let s = "She said: \"hi there\" and left."
        XCTAssertEqual(CleanupSanitizer.strip(s), s)
    }

    func testKeepsHeresThePlainContent() {
        let s = "Here's the thing: we should ship on Monday."
        XCTAssertEqual(CleanupSanitizer.strip(s), s)
    }

    // MARK: - Edge quotes that are NOT a wrap (review 2026-08-26)

    /// Dictated dialogue starts AND ends with a quote, but those are two
    /// separate quotations — a prefix/suffix match alone stripped both and
    /// corrupted the user's own punctuation. A wrap only unwraps when the
    /// interior contains neither delimiter.
    func testDialogueEdgeQuotesSurvive() {
        let s = #""Hello," she said. "Go.""#
        XCTAssertEqual(CleanupSanitizer.strip(s), s)
        let curly = "“Hello,” she said. “Go.”"
        XCTAssertEqual(CleanupSanitizer.strip(curly), curly)
    }

    /// …while a genuine packaging wrap (interior clean of the delimiter)
    /// still unwraps.
    func testGenuineWrapStillUnwraps() {
        XCTAssertEqual(CleanupSanitizer.strip(#""Hello world.""#), "Hello world.")
        XCTAssertEqual(CleanupSanitizer.strip("«Hello world.»"), "Hello world.")
    }
}
