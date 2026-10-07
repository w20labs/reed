import XCTest
@testable import Reed

/// End-of-sentence value corrections resolved by rule (field 2026-10-06):
/// the on-device model kept "7:00 PM" in "Meet at 7:00 PM, sorry, 5:00 PM."
final class TailCorrectionTests: XCTestCase {
    func testValueCorrectionsResolve() {
        let cases: [(String, String)] = [
            ("Meet at 7:00 PM sorry, 5:00 PM.", "Meet at 5:00 PM."),
            ("Meet at 7:00 PM, sorry, 5:00 PM.", "Meet at 5:00 PM."),
            ("Let's meet at 7:00 PM. Sorry, 5:00 PM.", "Let's meet at 5:00 PM."),
            ("Meet at 7:00 PM, sorry, at 5:00 PM.", "Meet at 5:00 PM."),
            ("The budget is $3,000, sorry, $4,000.", "The budget is $4,000."),
            ("The budget is $3 thousand. Sorry, $4 thousand.", "The budget is $4 thousand."),
            ("Raise $1.2 million, I mean $1.5 million.", "Raise $1.5 million."),
            ("Book the table for six, no wait, eight.", "Book the table for eight."),
            ("The code is 1234, no, 1243.", "The code is 1243."),
            ("Call me on Tuesday, I mean Wednesday.", "Call me on Wednesday."),
            ("Call me on Tuesday, I mean on Wednesday.", "Call me on Wednesday."),
            ("Ship it Friday, actually no, Monday.", "Ship it Monday."),
            ("Send the file to bob@example.com, sorry, alice@example.com.", "Send the file to alice@example.com."),
            ("Thanks for the notes. Meet at 7:00 PM, sorry, 5:00 PM.\nSee you there.",
             "Thanks for the notes. Meet at 5:00 PM.\nSee you there."),
        ]
        for (input, want) in cases {
            XCTAssertEqual(TailCorrection.apply(input), want, input)
        }
    }

    func testEverythingElseIsUntouched() {
        let unchanged = [
            "Move it to the left. Sorry, right.",           // plain words: the model's call
            "Let's meet Tuesday, sorry, Wednesday at three.", // the tail is more than a value
            "It's not Tuesday, it's Wednesday.",             // no cue
            "I'm sorry, I can't make it today.",
            "I'm sorry, $4 thousand is too much.",
            "No, I think we should wait until Monday.",
            "Do it now. No.",                                // nothing after the cue
            "I have two, no, three kids.",
            "Is it 5? No, 6.",                               // a question answered
            "Call me on Tuesday, sorry, by Wednesday.",      // a different preposition
            "Meet at 7:00 PM, sorry, Wednesday.",            // a different kind
            "Spacing  and\n\nnewlines stay  exactly.",
        ]
        for input in unchanged {
            XCTAssertEqual(TailCorrection.apply(input), input, input)
        }
    }
}
