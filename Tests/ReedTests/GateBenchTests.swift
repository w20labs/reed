import XCTest
@testable import Reed

/// Cleanup-quality track (2026-08-29): what does the acceptance gate reject,
/// and why? Runs disfluent dictations — the corpus verbatims, the email
/// dictations, and field cases — through the real on-device model exactly
/// as LocalCleanup does (structural hint → prompt choice → gate), and
/// prints every verdict with the rule that fired, so the mix can be read
/// off instead of guessed.
///
/// Gated: REED_GATE_BENCH=1 swift test --filter GateBenchTests
/// Lines: GT|<n>|<verdict>|<repair-hint>|<input>|<model output>
final class GateBenchTests: XCTestCase {
    private let root = VoiceCorpus.root

    static func plainWords(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'").split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map { $0.replacingOccurrences(of: "'", with: "") }
    }

    /// Negations by the stated policy — "not", "never", "cannot", any
    /// "n't" — with an adjacent repeat counted once ("hasn't hasn't been" is
    /// one negation stumbled over, not two). Independent arithmetic, not
    /// the gate's.
    static func negations(_ text: String) -> Int {
        let tokens = text.lowercased().replacingOccurrences(of: "’", with: "'").split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        var count = 0
        var previous = ""
        for token in tokens {
            let negation = ["not", "never", "cannot"].contains(token) || token.hasSuffix("n't")
            if negation, token != previous { count += 1 }
            previous = token
        }
        return count
    }

    /// Field cases, each a real or near-real dictation with the fix a person
    /// would want. The first two are from 2026-08-28 (both gate-rejected).
    static let fieldCases = [
        "Ship it Friday and tell them tell the team.",
        "Can you move the design review to Thursday afternoon, add Nadia and Toby to the invite and attach latest mockups from shared folder.",
        "I want to I want to go over the numbers first.",
        "Send it to the to the whole team by noon.",
        "We should probably we should ship on Friday.",
        "Let's meet at three, no, at four in the afternoon.",
        "It was really really bad.",
        "Move it to the left. Sorry, right.",
        "Send the invoice to Bob. Wait, no, to Alice, not Bob.",
        "So the plan the plan is to ship on Monday.",
        "Is this sentence is grammatically correct?",
        "Okay so um I think we need to um revisit the budget.",
        "Tell Dana tell Dana to call me back.",
        "The deployment finished around eleven last night all tests passed and the client confirmed they're happy.",
        // The user's two-minute reads (2026-08-29): every stumble the model fixed and the gate refused.
        "First can someone and Dana and Fel can someone add Dana and Felix to the launch channel they are both asking for updates.",
        "And support hasn't hasn't been trained on the new settings pane yet.",
        "Nadia reproduced it twice on her on the office Wi-Fi and once on her phone's hotspot so it's not one machine.",
        "The demo video should be ready on the ready to go on on the day not day after.",
        "I will send the revised timeline to everyone by 3 o'clock or by the end of day at the least latest if review runs long.",
        "One On the budget side, the invoice from the contractor came in at $3,162.",
        "Thanks and let me know if any of this does doesn't work for you.",
        "The short version is that uh the onboarding flow is still has an issue where the model download stalls."
    ]

    @MainActor
    func testGateVerdicts() async throws {
        guard ProcessInfo.processInfo.environment["REED_GATE_BENCH"] == "1" else { throw XCTSkip("set REED_GATE_BENCH=1") }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else { throw XCTSkip("no Foundation Models") }
        setvbuf(stdout, nil, _IOLBF, 0)
        // Loud, not silent (audit 2026-08-30): a missing corpus used to
        // try?-degrade 78 cases to 22 while still reporting ok.
        var inputs = Self.fieldCases
        let clipsData = try Data(contentsOf: URL(fileURLWithPath: "\(root)/clips_ref.json"))
        let clips = try XCTUnwrap(try JSONSerialization.jsonObject(with: clipsData) as? [[String: Any]])
        inputs += clips.compactMap { $0["verbatim"] as? String }
        let emailData = try Data(contentsOf: URL(fileURLWithPath: "\(root)/email_dictations.json"))
        let emails = try XCTUnwrap(try JSONSerialization.jsonObject(with: emailData) as? [String: String])
        inputs += emails.keys.sorted().compactMap { emails[$0] }
        // Exact, not a floor (review 2026-09-01): a floor let eight entries
        // vanish while the tally still graded "the" corpus. Any drop in the
        // loaders above or a resized corpus is a deliberate re-baseline.
        XCTAssertEqual(clips.count, 10, "clips_ref.json must hold the 10 everyday clips")
        XCTAssertEqual(emails.count, 10, "email_dictations.json must hold the 10 email dictations")
        XCTAssertEqual(inputs.count, Self.fieldCases.count + clips.count + emails.count,
                       "an entry was dropped while loading — the tally would grade a different corpus")
        XCTAssertEqual(inputs.count, 42, "corpus changed size — re-baseline gate.max_refusals deliberately, then update this pin")
        // Required, not optional, and resolved BEFORE the model warms: a
        // missing or broken ceilings file fails in milliseconds instead of
        // quietly disarming the bench (review 2026-09-01).
        let ceiling = try BenchBaselines.require(["gate", "max_refusals"])
        AICleanup.prewarm()
        _ = await AICleanup.clean("warm up")
        var tally: [String: Int] = [:]
        var accepted: [(String, String)] = []
        for (n, input) in inputs.enumerated() {
            // One chunk at a time, as LocalCleanup.cleanLine does.
            for chunk in SentenceChunker.split(input, coalesce: true) {
                let structural = LocalCleanup.structuralReason(chunk)
                guard let output = await AICleanup.clean(chunk, repair: structural != nil).text, !output.isEmpty else {
                    print("GT|\(n)|model-empty|\(structural ?? "-")|\(chunk)|")
                    tally["model-empty", default: 0] += 1
                    continue
                }
                let verdict: String
                if !LocalCleanup.looksFaithful(input: chunk, output: output, minRecall: 0.5, maxGrowth: 3) {
                    verdict = "recall"
                } else if let why = CleanupGate.rejection(input: chunk, output: output, repairHint: structural != nil) {
                    verdict = why.rawValue
                } else {
                    verdict = output == chunk ? "accept-unchanged" : "accept"
                }
                tally[verdict, default: 0] += 1
                print("GT|\(n)|\(verdict)|\(structural ?? "-")|\(chunk)|\(output)")
                if verdict == "accept" || verdict == "accept-unchanged" { accepted.append((chunk, output)) }
            }
        }
        print("GT|tally|" + tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        let refused = tally.filter { !$0.key.hasPrefix("accept") && $0.key != "unchanged" }.values.reduce(0, +)
        XCTAssertLessThanOrEqual(Double(refused), ceiling,
            "\(refused) refusals exceed the committed ceiling \(Int(ceiling)) (docs/bench/baselines.json)")
        // Per-case safety, independent of the gate and of the count (review
        // 2026-09-08): an accepted output never loses a negation and never
        // holds a word that was not spoken — checked by its own arithmetic,
        // not the gate's.
        for (input, output) in accepted {
            XCTAssertEqual(Self.negations(input), Self.negations(output), "an accepted output changed a negation: \(input)")
            let spoken = Set(Self.plainWords(input))
            XCTAssertTrue(Self.plainWords(output).allSatisfy(spoken.contains), "an accepted output holds an unspoken word: \(input)")
        }
        XCTAssertGreaterThan(accepted.count, 0)
    }
}
