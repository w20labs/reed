import Foundation

/// Natural self-correction fixtures (2026-10-14). `research` is the frozen
/// set from /private/tmp/reed-self-correction-research/cases.json — the
/// failures the cleanup work was tuned against (regression). `validation`
/// was written and committed before any prompt or rule changed, and is
/// never used for tuning: it measures whether the change generalizes.
enum SelfCorrectionFixtures {
    enum Kind: String { case repair, preserve }

    struct Case {
        let id: String
        let kind: Kind
        let text: String
        let expected: String
    }

    static let research: [Case] = [
        .init(id: "U01", kind: .repair, text: "We were going to go. We are going to go.", expected: "We are going to go."),
        .init(id: "U02", kind: .repair, text: "We were going to, we are going to go.", expected: "We are going to go."),
        .init(id: "U03", kind: .repair, text: "That we were going to go. We are going to go.", expected: "We are going to go."),
        .init(id: "U04", kind: .repair, text: "I want to send this on Thursday. On Friday.", expected: "I want to send this on Friday."),
        .init(id: "U05", kind: .repair, text: "I think we can we should postpone the launch.", expected: "I think we should postpone the launch."),
        .init(id: "U06", kind: .repair, text: "Send it to Sam to Priya.", expected: "Send it to Priya."),
        .init(id: "U07", kind: .repair, text: "I can approve I cannot approve the refund.", expected: "I cannot approve the refund."),
        .init(id: "U08", kind: .repair, text: "The total is twelve, fifteen dollars.", expected: "The total is fifteen dollars."),
        .init(id: "M01", kind: .repair, text: "We were going to go. Scratch that. We are going to go.", expected: "We are going to go."),
        .init(id: "M02", kind: .repair, text: "We were going to, scratch that, we are going to go.", expected: "We are going to go."),
        .init(id: "M03", kind: .repair, text: "Send the report to Sam, I mean Priya.", expected: "Send the report to Priya."),
        .init(id: "M04", kind: .repair, text: "Meet at seven, no wait, five.", expected: "Meet at five."),
        .init(id: "M05", kind: .repair, text: "I can approve the refund. Actually, no, I cannot approve the refund.", expected: "I cannot approve the refund."),
        .init(id: "M06", kind: .repair, text: "The deadline is Friday, sorry, not Friday, Monday.", expected: "The deadline is Monday."),
        .init(id: "C01", kind: .preserve, text: "We were going to go yesterday. We are going to go tomorrow.", expected: "We were going to go yesterday. We are going to go tomorrow."),
        .init(id: "C02", kind: .preserve, text: "We were going to go, but we are going to stay.", expected: "We were going to go, but we are going to stay."),
        .init(id: "C03", kind: .preserve, text: "We must test this. We must test this before release.", expected: "We must test this. We must test this before release."),
        .init(id: "C04", kind: .preserve, text: "I really really want this to work.", expected: "I really really want this to work."),
        .init(id: "C05", kind: .preserve, text: "Do not delete the old backups until Maya approves.", expected: "Do not delete the old backups until Maya approves."),
        .init(id: "C06", kind: .preserve, text: "I’m sorry we missed the deadline. We will send an update Friday.", expected: "I’m sorry we missed the deadline. We will send an update Friday."),
        .init(id: "C07", kind: .preserve, text: "The phrase “scratch that” appears in the transcript.", expected: "The phrase “scratch that” appears in the transcript."),
        .init(id: "C08", kind: .preserve, text: "Should we postpone the launch?", expected: "Should we postpone the launch?"),
        .init(id: "C09", kind: .preserve, text: "Priya approved the $480 refund, but Maya did not approve the $840 invoice.", expected: "Priya approved the $480 refund, but Maya did not approve the $840 invoice."),
        .init(id: "C10", kind: .preserve, text: "We had had several discussions before deciding.", expected: "We had had several discussions before deciding."),
        .init(id: "C11", kind: .preserve, text: "Monday or Tuesday would work; Friday would not.", expected: "Monday or Tuesday would work; Friday would not."),
        .init(id: "C12", kind: .preserve, text: "Please send the draft to Sam and Priya.", expected: "Please send the draft to Sam and Priya."),
        .init(id: "P01", kind: .repair, text: "Can you send this to the team? We were going to go. We are going to go. Please update the calendar.", expected: "Can you send this to the team? We are going to go. Please update the calendar."),
        .init(id: "P02", kind: .repair, text: "I want to send this on Thursday. On Friday. Priya should review it first, and we must not publish it yet.", expected: "I want to send this on Friday. Priya should review it first, and we must not publish it yet."),
        .init(id: "P03", kind: .repair, text: "The test results are ready. Send them to Sam, I mean Priya. Keep the raw logs for 72 hours.", expected: "The test results are ready. Send them to Priya. Keep the raw logs for 72 hours."),
        .init(id: "P04", kind: .preserve, text: "We were going to go, but we are going to stay. Please tell Priya. I’m sorry for the last-minute change.", expected: "We were going to go, but we are going to stay. Please tell Priya. I’m sorry for the last-minute change."),
    ]

    static let validation: [Case] = [
        .init(id: "V01", kind: .repair, text: "I'll call you at noon. I'll call you at one.", expected: "I'll call you at one."),
        .init(id: "V02", kind: .repair, text: "The meeting is in room four, sorry, room five.", expected: "The meeting is in room five."),
        .init(id: "V03", kind: .repair, text: "Book the flight for Tuesday, I mean Wednesday.", expected: "Book the flight for Wednesday."),
        .init(id: "V04", kind: .repair, text: "Ask Daniel to, scratch that, ask Mia to review it.", expected: "Ask Mia to review it."),
        .init(id: "V05", kind: .repair, text: "We should we must finish the audit today.", expected: "We must finish the audit today."),
        .init(id: "V06", kind: .repair, text: "The office is closed on Monday, sorry, not Monday, Tuesday.", expected: "The office is closed on Tuesday."),
        .init(id: "V07", kind: .repair, text: "Let's use the blue one. Let's use the green one.", expected: "Let's use the green one."),
        .init(id: "V08", kind: .repair, text: "He has three, no wait, four kids.", expected: "He has four kids."),
        .init(id: "V09", kind: .repair, text: "Please send it to the legal team. To the finance team.", expected: "Please send it to the finance team."),
        .init(id: "V10", kind: .repair, text: "Can you can you review the pull request today?", expected: "Can you review the pull request today?"),
        .init(id: "V11", kind: .preserve, text: "I'll call you at noon, and I'll call him at one.", expected: "I'll call you at noon, and I'll call him at one."),
        .init(id: "V12", kind: .preserve, text: "Let's use the blue one for the header and the green one for the footer.", expected: "Let's use the blue one for the header and the green one for the footer."),
        .init(id: "V13", kind: .preserve, text: "She said to scratch that idea because it won't work.", expected: "She said to scratch that idea because it won't work."),
        .init(id: "V14", kind: .preserve, text: "The launch isn't in March, it's in April.", expected: "The launch isn't in March, it's in April."),
        .init(id: "V15", kind: .preserve, text: "We were late. We are never late.", expected: "We were late. We are never late."),
        .init(id: "V16", kind: .preserve, text: "Thank you, thank you so much.", expected: "Thank you, thank you so much."),
        .init(id: "V17", kind: .preserve, text: "I mean it, this has to ship on Friday.", expected: "I mean it, this has to ship on Friday."),
        .init(id: "V18", kind: .preserve, text: "Sorry, I can't make it to the call today.", expected: "Sorry, I can't make it to the call today."),
        .init(id: "V19", kind: .preserve, text: "Please do not share the password with anyone.", expected: "Please do not share the password with anyone."),
        .init(id: "V20", kind: .preserve, text: "We tested it on Monday. We tested it again on Friday.", expected: "We tested it on Monday. We tested it again on Friday."),
        .init(id: "V21", kind: .preserve, text: "It was a long, long day.", expected: "It was a long, long day."),
        .init(id: "V22", kind: .preserve, text: "Call Sam. Call Priya too.", expected: "Call Sam. Call Priya too."),
    ]

    /// Fresh set (2026-10-14, tenth review): written and committed before
    /// any run, never used for tuning. Threshold agreed with the maintainer
    /// before inspection: preservation ≥ 14/15 AND repairs ≥ 8/15; latency
    /// reported, not gated. If Apple misses it, the limitation is reported —
    /// no further exceptions are added to chase it.
    static let fresh: [Case] = [
        .init(id: "F01", kind: .repair, text: "Put the meeting on Wednesday, sorry, Thursday afternoon.", expected: "Put the meeting on Thursday afternoon."),
        .init(id: "F02", kind: .repair, text: "The package weighs two kilos, I mean three kilos.", expected: "The package weighs three kilos."),
        .init(id: "F03", kind: .repair, text: "Let's order the blue chairs. Let's order the gray chairs.", expected: "Let's order the gray chairs."),
        .init(id: "F04", kind: .repair, text: "Invite Tom to the review, no wait, invite Lena to the review.", expected: "Invite Lena to the review."),
        .init(id: "F05", kind: .repair, text: "The train leaves at nine, scratch that, at ten.", expected: "The train leaves at ten."),
        .init(id: "F06", kind: .repair, text: "I will finish the slides tonight. I will finish the slides tomorrow.", expected: "I will finish the slides tomorrow."),
        .init(id: "F07", kind: .repair, text: "We should we could try the other vendor.", expected: "We could try the other vendor."),
        .init(id: "F08", kind: .repair, text: "Send it to the design team, sorry, the product team.", expected: "Send it to the product team."),
        .init(id: "F09", kind: .repair, text: "My flight is on Monday. My flight is on Tuesday.", expected: "My flight is on Tuesday."),
        .init(id: "F10", kind: .repair, text: "Add milk and eggs, actually no, add milk and butter.", expected: "Add milk and butter."),
        .init(id: "F11", kind: .repair, text: "The budget is five thousand, I mean six thousand dollars.", expected: "The budget is six thousand dollars."),
        .init(id: "F12", kind: .repair, text: "I think it's it's broken.", expected: "I think it's broken."),
        .init(id: "F13", kind: .repair, text: "Can you check the the logs before lunch?", expected: "Can you check the logs before lunch?"),
        .init(id: "F14", kind: .repair, text: "The office opens at eight, no, at seven thirty.", expected: "The office opens at seven thirty."),
        .init(id: "F15", kind: .repair, text: "Please call Anna, I mean, please email Anna.", expected: "Please email Anna."),
        .init(id: "G01", kind: .preserve, text: "I wanted tea, but I ordered coffee.", expected: "I wanted tea, but I ordered coffee."),
        .init(id: "G02", kind: .preserve, text: "The first draft was short. The second draft is much longer.", expected: "The first draft was short. The second draft is much longer."),
        .init(id: "G03", kind: .preserve, text: "Sorry for the delay, the report is attached.", expected: "Sorry for the delay, the report is attached."),
        .init(id: "G04", kind: .preserve, text: "I mean what I say.", expected: "I mean what I say."),
        .init(id: "G05", kind: .preserve, text: "No, I don't think that's right.", expected: "No, I don't think that's right."),
        .init(id: "G06", kind: .preserve, text: "We met on Monday and again on Tuesday.", expected: "We met on Monday and again on Tuesday."),
        .init(id: "G07", kind: .preserve, text: "It's very, very important.", expected: "It's very, very important."),
        .init(id: "G08", kind: .preserve, text: "Do not merge this until the tests pass.", expected: "Do not merge this until the tests pass."),
        .init(id: "G09", kind: .preserve, text: "Actually, the meeting went well.", expected: "Actually, the meeting went well."),
        .init(id: "G10", kind: .preserve, text: "She said, \"scratch that line,\" and moved on.", expected: "She said, \"scratch that line,\" and moved on."),
        .init(id: "G11", kind: .preserve, text: "The NASA and ESA teams will meet in May.", expected: "The NASA and ESA teams will meet in May."),
        .init(id: "G12", kind: .preserve, text: "Option A is cheaper; option B is faster.", expected: "Option A is cheaper; option B is faster."),
        .init(id: "G13", kind: .preserve, text: "We had had enough by noon.", expected: "We had had enough by noon."),
        .init(id: "G14", kind: .preserve, text: "Call me at five, not at six.", expected: "Call me at five, not at six."),
        .init(id: "G15", kind: .preserve, text: "Thanks again, and see you on Friday.", expected: "Thanks again, and see you on Friday."),
    ]
    static let freshThreshold = (preserve: 14, repair: 8)

    /// Reference match: case- and punctuation-folded word sequences, the
    /// research report's scoring.
    static func matches(_ output: String, _ expected: String) -> Bool {
        fold(output) == fold(expected)
    }

    static func fold(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "$" }
            .map(String.init)
    }
}
