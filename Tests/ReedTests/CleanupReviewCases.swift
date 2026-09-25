import Foundation
@testable import Reed

/// The retained examples from PR #322's review rounds, not generated from
/// cleanup output. Each expected string is the review's keep/edit decision.
enum CleanupReviewCases {
    struct TextCase {
        let name: String
        let input: String
        let expected: String
        let modelExpected: String

        init(_ name: String, _ input: String, _ expected: String, modelExpected: String? = nil) {
            self.name = name
            self.input = input
            self.expected = expected
            self.modelExpected = modelExpected ?? expected
        }

        static func keep(_ name: String, _ text: String) -> Self { .init(name, text, text) }
    }

    static let restarts: [TextCase] = [
        .init("field restart", "Tell me tell me what you think.", "Tell me what you think."),
        .init("mid-sentence restart", "I said something like something like this is fine.", "I said something like this is fine."),
        .init("function-word phrase", "I want to I want to go over the numbers first.", "I want to go over the numbers first."),
        .init("plan restart", "So the plan the plan is to ship on Monday.", "So the plan is to ship on Monday."),
        .init("comma on abandoned copy", "Tell me, tell me what you think.", "Tell me what you think."),
        .init("link is not necessarily a chain", "Please go to go to Settings.", "Please go to Settings."),
        .init("by is not necessarily a chain", "Send it by send it by Friday.", "Send it by Friday."),
        .init("contraction is not a delimiter", "It's fine it's fine to go.", "It's fine to go."),
        .init("modal preserved by presence", "We should ship it we should ship it today.", "We should ship it today."),
        .init("kept copy may end a sentence", "Tell me tell me. That is all.", "Tell me. That is all.")
    ]

    static let repetitions: [TextCase] = [
        .keep("single-word emphasis", "It was really really bad."),
        .keep("longer emphasis", "Really really really really bad."),
        .keep("longer no repetition", "No no no no no no."),
        .keep("three-copy chain", "Again and again and again."),
        .keep("five-copy chain", "Again and again and again and again and again."),
        .keep("by chain", "One by one by one by one."),
        .keep("after chain", "Day after day after day.")
    ]

    static let sentences: [TextCase] = [
        .keep("complete negated sentences", "Never share it. Never share it outside the team."),
        .keep("complete affirmative sentences", "It's done. It's done now."),
        .keep("gate-only negation guard", "I do not I do not want it."),
        .keep("kept copy crosses a sentence", "We need more time, more. Time is running out."),
        .keep("kept copy crosses a sentence without comma", "We need more time more. Time is running out.")
    ]

    static let delimiters: [TextCase] = [
        .init("opening straight quote", "He said \"tell me tell me what you think.\"", "He said \"tell me what you think.\""),
        .init("opening curly quote", "He said “tell me tell me what you think.”", "He said “tell me what you think.”"),
        .init("opening parenthesis", "Please (send it send it today).", "Please (send it today)."),
        .init("opening single quote", "Say 'go on go on' twice.", "Say 'go on' twice."),
        .keep("closer at span end", "He said \"tell me\" tell me what you think."),
        .keep("straight closer before comma", "He said \"tell me\", tell me what you think."),
        .keep("curly closer before comma", "He said “tell me”, tell me what you think."),
        .keep("parenthesis before comma", "Please (send it), send it today."),
        .keep("bracket before comma", "Please [send it], send it today."),
        .keep("straight closer inside span", "He said \"go on\" and go on and finish it."),
        .keep("curly closer inside span", "He said “go on” and go on and finish it."),
        .keep("parenthesis inside span", "Please (send it) now, send it now to the team."),
        .keep("opener inside abandoned copy", "Tell \"me tell me what you think.")
    ]

    static let quotations: [TextCase] = [
        .keep("quoted instruction", "Please say \"please say hello\" twice."),
        .keep("curly quoted instruction", "Please say “please say hello” twice."),
        .keep("parenthesized instruction", "Type (type this) again."),
        .keep("nested curly quotation", "He said “write down ‘write down the address’.”"),
        .keep("nested straight quotation", "He said \"she said 'she said hi' then\" and left.")
    ]

    static let paragraphs: [TextCase] = [
        .init("collapse before blank line", "Tell me tell me\n\nWhat you think.", "Tell me\n\nWhat you think.",
              modelExpected: "Tell me.\n\nWhat you think."),
        .init("copies across a line break", "Tell me\nTell me.", "Tell me\nTell me.",
              modelExpected: "Tell me.\nTell me.")
    ]

    static let bounded: [TextCase] = [
        .init("eight-word ceiling", "A b c d e f g h a b c d e f g h done.", "A b c d e f g h done."),
        .keep("nine words exceed ceiling", "A b c d e f g h I a b c d e f g h I done."),
        .init("one collapse at each position", "Tell me tell me tell me what you think.", "Tell me tell me what you think."),
        .init("filler pass still collapses once", "Um tell me tell me tell me what you think.", "Tell me tell me what you think.")
    ]

    static var all: [TextCase] { restarts + repetitions + sentences + delimiters + quotations + paragraphs + bounded }

    struct SeamCase {
        let name: String
        let head: String
        let next: String
        let expected: String
        let decision: ReviewRecord.JoinDecision

        init(_ name: String, _ head: String, _ next: String, _ expected: String, _ decision: ReviewRecord.JoinDecision) {
            self.name = name
            self.head = head
            self.next = next
            self.expected = expected
            self.decision = decision
        }
    }

    static let joined: [SeamCase] = [
        .init("field seam", "Hi my name is.", "My name is Aram.", "Hi my name is Aram.", .restartCollapsed),
        .init("whole head restart", "My name is.", "My name is Aram.", "My name is Aram.", .restartCollapsed),
        .init("proper name", "Please ask Dana Connor.", "Dana Connor to join.", "Please ask Dana Connor to join.", .restartCollapsed),
        .init("sentence capital", "Okay. Tell me.", "Tell me what you think.", "Okay. Tell me what you think.", .restartCollapsed),
        .init("pronoun capital", "So I think.", "I think we should go.", "So I think we should go.", .restartCollapsed),
        .init("opening quote travels", "He said \"tell me.", "Tell me what you think.\"", "He said \"tell me what you think.\"", .restartCollapsed),
        .init("unrelated paragraphs survive", "First.\n\nHi my name is.", "My name is Aram.\n\nLast.",
              "First.\n\nHi my name is Aram.\n\nLast.", .restartCollapsed),
        .init("earlier sentence outside match", "I said. Tell me.", "Tell me more.", "I said. Tell me more.", .restartCollapsed)
    ]

    static let refused: [SeamCase] = [
        .init("negation", "Do not do it.", "Do not do it now.", "Do not do it. Do not do it now.", .sentenceEnd),
        .init("single-word emphasis", "It was really.", "Really bad.", "It was really. Really bad.", .sentenceEnd),
        .init("longer emphasis", "It was really really.", "Really really bad.", "It was really really. Really really bad.", .sentenceEnd),
        .init("chain joins without deletion", "We tried again and.", "Again and again.", "We tried again and again and again.", .gluedBreath),
        .init("earlier head sentence", "I said yes. Tell me.", "Yes tell me more.", "I said yes. Tell me. Yes tell me more.", .sentenceEnd),
        .init("sentence inside kept copy", "We need more time.", "More. Time is running out.", "We need more time. More. Time is running out.", .sentenceEnd),
        .init("closed quotation", "He said \"tell me.\"", "Tell me more.", "He said \"tell me.\" Tell me more.", .sentenceEnd),
        .init("closer followed by comma", "He said \"tell me\",", "Tell me what you think.", "He said \"tell me\", Tell me what you think.", .sentenceEnd),
        .init("closer inside head", "He said \"go on\" and.", "Go on and finish it.", "He said \"go on\" and go on and finish it.", .gluedBreath),
        .init("quoted next piece", "Please say.", "\"Please say hello\" twice.", "Please say. \"Please say hello\" twice.", .sentenceEnd),
        .init("nested next quotation", "He said “write down.", "‘Write down the address’.”", "He said “write down. ‘Write down the address’.”", .sentenceEnd),
        .init("match not on last head line", "Hi my name is.\n\nOkay.", "My name is Aram.", "Hi my name is.\n\nOkay. My name is Aram.", .sentenceEnd),
        .init("match not on first next line", "Tell me.", "Okay.\n\nTell me more.", "Tell me. Okay.\n\nTell me more.", .sentenceEnd)
    ]
}
