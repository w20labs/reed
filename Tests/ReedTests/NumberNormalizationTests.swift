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

