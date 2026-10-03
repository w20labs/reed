import XCTest
@testable import Reed

/// Inverse text normalization (finding 3, 2026-08-29), anchored to the
/// numbers corpus (docs/bench/itn_before.txt). Style: one–nine as words in
/// prose, ten and up as digits; a count after a label word is a digit;
/// ordinals are digits only in dates; clock times are H:MM.
final class NumberNormalizationTests: XCTestCase {
    private func fmt(_ text: String) -> String { CorrectionPass.apply(text, active: []).text }

    func testCardinalsTenAndUpBecomeDigits() {
        XCTAssertEqual(fmt("There were two hundred and fifty participants and twelve speakers."),
                       "There were 250 participants and 12 speakers.")
        XCTAssertEqual(fmt("three thousand one hundred and sixty two people came"), "3,162 people came")
        XCTAssertEqual(fmt("about three hundred over the estimate, so roughly seven percent"),
                       "about 300 over the estimate, so roughly 7%")
    }

    func testSmallCountsStayWordsUnlessLabelled() {
        XCTAssertEqual(fmt("Add two avocados, a dozen bananas and one bag of coffee beans."),
                       "Add two avocados, a dozen bananas and one bag of coffee beans.")
        XCTAssertEqual(fmt("I need five minutes, maybe ten, before the one on one."),
                       "I need five minutes, maybe 10, before the one on one.")
        XCTAssertEqual(fmt("phase two starts Monday and step three follows"), "phase 2 starts Monday and step 3 follows")
        XCTAssertEqual(fmt("one of them is missing"), "one of them is missing")
    }

    func testOrdinalsAreDigitsOnlyInDates() {
        XCTAssertEqual(fmt("It's due on the fifteenth of March."), "It's due on the 15th of March.")
        XCTAssertEqual(fmt("due on the fifteenth of march at nine thirty"), "due on the 15th of March at 9:30")
        XCTAssertEqual(fmt("due on fifteenth of march at 9:30"), "due on 15th of March at 9:30")
        XCTAssertEqual(fmt("from Friday the twelfth to Wednesday the seventeenth"), "from Friday the 12th to Wednesday the 17th")
        XCTAssertEqual(fmt("lands at eleven forty five p m on the third"), "lands at 11:45 PM on the 3rd")
        XCTAssertEqual(fmt("Room four oh two, second floor, extension one one nine."), "Room 402, second floor, extension 119.")
        XCTAssertEqual(fmt("the first half of the year"), "the first half of the year")
        XCTAssertEqual(fmt("March twenty first"), "March 21st")
    }

    func testClockTimes() {
        XCTAssertEqual(fmt("Let's meet at three o'clock, or half past four if the review runs long."),
                       "Let's meet at 3 o'clock, or 4:30 if the review runs long.")
        XCTAssertEqual(fmt("at nine thirty in the morning"), "at 9:30 in the morning")
        XCTAssertEqual(fmt("at 9 30 in the morning"), "at 9:30 in the morning")
        XCTAssertEqual(fmt("due at 9.30 in the morning"), "due at 9:30 in the morning")
        XCTAssertEqual(fmt("My flight lands at 11.45 pm on the third."), "My flight lands at 11:45 PM on the 3rd.")
        XCTAssertEqual(fmt("quarter to five"), "4:45")
        // No cue, no meridiem: a number run stays spoken.
        XCTAssertEqual(fmt("we counted nine thirty times"), "we counted nine thirty times")
        XCTAssertEqual(fmt("it cost ten ninety nine at the store"), "it cost ten ninety nine at the store")
    }

    func testExistingFormsKeepPriority() {
        XCTAssertEqual(fmt("The invoice total is three thousand one hundred and sixty two dollars."),
                       "The invoice total is $3,162.")
        XCTAssertEqual(fmt("call me on five five five zero one two three four five six"), "call me on (555) 012-3456")
        XCTAssertEqual(fmt("we shipped version two point three point one"), "we shipped v2.3.1")
    }

    /// Spoken "dot" between numbers is a version or an address, and it has to
    /// convert whole — the reported defect left "version zero dot three dot
    /// five" as "version 0 dot three dot five", one component converted and
    /// the rest spoken. A dotted run needs no label word, so it also fires
    /// mid-sentence; domains and emails are claimed first and must survive.
    func testDottedNumbersConvertWhole() {
        XCTAssertEqual(fmt("zero dot three dot five"), "0.3.5")
        XCTAssertEqual(fmt("we are running zero dot three dot five"), "we are running 0.3.5")
        XCTAssertEqual(fmt("0 dot 3 dot 5"), "0.3.5")
        XCTAssertEqual(fmt("two dot three dot one"), "2.3.1")
        XCTAssertEqual(fmt("three dot five"), "3.5")
        // The "version" label keeps its own rendering, either separator.
        XCTAssertEqual(fmt("version zero dot three dot five"), "v0.3.5")
        XCTAssertEqual(fmt("version zero point three point five"), "v0.3.5")
        XCTAssertEqual(fmt("version three dot five"), "v3.5")
        // Addresses are the same shape.
        XCTAssertEqual(fmt("ten dot zero dot zero dot one"), "10.0.0.1")
        XCTAssertEqual(fmt("192 dot 168 dot 1 dot 1"), "192.168.1.1")
        // Other label words no longer leak a half-converted run.
        XCTAssertEqual(fmt("section three dot five"), "section 3.5")
        XCTAssertEqual(fmt("chapter two dot one"), "chapter 2.1")
    }

    /// A component is rendered as text, never through `Int`: "0 dot 03" is
    /// 0.03, and an integer round-trip silently changes the value.
    func testDottedNumbersKeepLeadingZeros() {
        XCTAssertEqual(fmt("0 dot 03"), "0.03")
        XCTAssertEqual(fmt("1 dot 02 dot 3"), "1.02.3")
        XCTAssertEqual(fmt("0 dot 00 dot 1"), "0.00.1")
    }

    /// A version or address dictated digit by digit converts whole; before,
    /// only the component the cardinal rule happened to reach converted
    /// ("zero dot three dot one zero" → "0.3.1 zero").
    func testDottedNumbersSpokenDigitByDigit() {
        XCTAssertEqual(fmt("zero dot three dot one zero"), "0.3.10")
        XCTAssertEqual(fmt("one nine two dot one six eight dot one dot one"), "192.168.1.1")
        XCTAssertEqual(fmt("version one dot two zero"), "v1.20")
        XCTAssertEqual(fmt("version one nine two dot one six eight"), "v192.168")
    }

    /// A compound keeps its arithmetic: digit-by-digit concatenation is for
    /// digits only, and applying it to "one hundred twenty" made it 10020
    /// (review 2026-10-02 — a regression against shipped v120.3).
    func testDottedNumbersKeepCompoundArithmetic() {
        XCTAssertEqual(fmt("version one hundred twenty point three"), "v120.3")
        XCTAssertEqual(fmt("version one hundred twenty dot three"), "v120.3")
        XCTAssertEqual(fmt("one hundred ninety two dot one hundred sixty eight dot one dot one"),
                       "192.168.1.1")
    }

    /// A component ends only where the number ends. Mixed digit tokens and
    /// digit words are one component, and a fraction is not capped at six
    /// digits ("0.123456 seven").
    func testDottedComponentsConsumeEveryNumericToken() {
        XCTAssertEqual(fmt("zero dot 0 five"), "0.05")
        XCTAssertEqual(fmt("1 nine two dot 168 dot 1 dot 1"), "192.168.1.1")
        XCTAssertEqual(fmt("zero dot one two three four five six seven"), "0.1234567")
        // A scale word after a digit run means the component was cut: the run
        // is declined whole rather than rendered as "1.192 hundred".
        XCTAssertEqual(fmt("one dot one nine two hundred"), "one dot one nine two hundred")
        XCTAssertEqual(fmt("zero dot one two three hundred"), "zero dot one two three hundred")
        XCTAssertEqual(fmt("nine dot one one thousand"), "nine dot one one thousand")
    }

    /// An incomplete version run declined by the `version` rule must not then
    /// be converted in part by the unlabelled dotted rule.
    func testDeclinedVersionRunIsNotConvertedByTheDottedRule() {
        XCTAssertEqual(fmt("version one dot two point"), "version one dot two point")
        XCTAssertEqual(fmt("version one point two dot three point"),
                       "version one point two dot three point")
    }

    /// A declined run must stay declined at every start position. The scanner
    /// retries each token, so after a run is rejected it walks into it and
    /// used to convert the suffix ("one dot one nine 200.3", review
    /// 2026-10-02) — a run may only begin where a number begins.
    func testDeclinedRunIsNotConvertedFromAnInteriorToken() {
        XCTAssertEqual(fmt("one dot one nine two hundred dot three"),
                       "one dot one nine two hundred dot three")
        XCTAssertEqual(fmt("version one dot one nine two hundred dot three"),
                       "version one dot one nine two hundred dot three")
        XCTAssertEqual(fmt("zero dot one two three hundred dot five"),
                       "zero dot one two three hundred dot five")
        XCTAssertEqual(fmt("nine dot one one thousand dot two"),
                       "nine dot one one thousand dot two")
    }

    /// Only single digits concatenate into one component: joining a token the
    /// recognizer already grouped would merge two separate numbers.
    func testAlreadyGroupedNumbersAreNotMergedIntoAComponent() {
        XCTAssertEqual(fmt("we have 250 1 dot 2 units"), "we have 250 1 dot 2 units")
        XCTAssertEqual(fmt("twelve 1 dot 2"), "12 1 dot 2")
    }

    func testDottedNumbersLeaveDomainsAndDanglingDotsAlone() {
        XCTAssertEqual(fmt("visit example dot com"), "visit example.com")
        XCTAssertEqual(fmt("email jane at example dot com"), "email jane@example.com")
        XCTAssertEqual(fmt("go to reed dot w20 dot ai"), "go to reed.w20.ai")
        XCTAssertEqual(fmt("check seven dot org"), "check 7.org")
        // A separator with no number after it is an unfinished version —
        // however many components the run already has (review 2026-10-02:
        // the guarantee held for one component and leaked for two).
        XCTAssertEqual(fmt("we're on version two dot"), "we're on version two dot")
        XCTAssertEqual(fmt("section three dot"), "section three dot")
        XCTAssertEqual(fmt("zero dot three dot"), "zero dot three dot")
        XCTAssertEqual(fmt("section three dot five dot"), "section three dot five dot")
        XCTAssertEqual(fmt("ten dot zero dot zero dot"), "ten dot zero dot zero dot")
        XCTAssertEqual(fmt("version two dot three dot"), "version two dot three dot")
        XCTAssertEqual(fmt("version one point zero point"), "version one point zero point")
        // Prose "dot" is not a separator.
        XCTAssertEqual(fmt("a dot matrix printer"), "a dot matrix printer")
        XCTAssertEqual(fmt("dot the i and cross the t"), "dot the i and cross the t")
        XCTAssertEqual(fmt("Ship the package to twenty two Baker Street, London."), "Ship the package to 22 Baker Street, London.")
    }

    /// Field 2026-08-29: the recognizer mixed digits and hyphenated words.
    func testMixedDigitAndHyphenatedShapes() {
        XCTAssertEqual(fmt("The invoice is 3,100 and sixty-two dollars due on the fifteenth of March."),
                       "The invoice is $3,162 due on the 15th of March.")
        XCTAssertEqual(fmt("two hundred and fifty-three people"), "253 people")
        XCTAssertEqual(fmt("Ship it to twenty-two Baker Street"), "Ship it to 22 Baker Street")
        XCTAssertEqual(fmt("we need four thousand and twenty-five dollars"), "we need $4,025")
        // A bare digit token stays as it is.
        XCTAssertEqual(fmt("there were 250 participants"), "there were 250 participants")
        XCTAssertEqual(fmt("at 4,200 feet"), "at 4,200 feet")
    }
}

