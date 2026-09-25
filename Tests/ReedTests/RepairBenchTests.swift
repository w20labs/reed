import XCTest
@testable import Reed

/// Repair-prompt trigger (list item after finding 5, 2026-08-29): as
/// isolated sentences the model leaves several field stumbles alone under
/// the generic prompt, and `structuralReason` does not fire for them, so
/// the repair prompt — which does fix them — is never chosen. Measure each
/// stumble under both prompts, with the gate's verdict.
///
/// Gated: REED_REPAIR_BENCH=1. Lines: RB|<n>|<hint>|<generic verdict>|<generic out>|<repair verdict>|<repair out>|<pipeline verdict>|<pipeline out>|<input>
final class RepairBenchTests: XCTestCase {
    static let inputs = [
        "Nadia reproduced it twice on her on the office Wi-Fi and once on her phone's hotspot.",
        "Thanks and let me know if any of this does doesn't work for you.",
        "I will send the revised timeline by the end of day at the least latest if review runs long.",
        "One On the budget side, the invoice from the contractor came in at $3,162.",
        "The short version is that uh the onboarding flow is still has an issue where the download stalls.",
        "First can someone and Dana and Fel can someone add Dana and Felix to the launch channel.",
        "And support hasn't hasn't been trained on the new settings pane yet.",
        "The demo video should be ready on the ready to go on the day not the day after.",
        "We had the review with the platform team on on Tuesday afternoon.",
        "Ship it Friday and tell them tell the team.",
        "So my proposal is that we we move the date to Wednesday.",
        "I agree with him marketing also wants another week for the launch video."
    ]

    @MainActor
    func testStumblesUnderBothPrompts() async throws {
        guard ProcessInfo.processInfo.environment["REED_REPAIR_BENCH"] == "1" else { throw XCTSkip("set REED_REPAIR_BENCH=1") }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else { throw XCTSkip("no Foundation Models") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        defer {
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        AICleanup.prewarm(); _ = await AICleanup.clean("warm up")
        var fixedGeneric = 0, fixedRepair = 0, fixedPipeline = 0, hinted = 0
        for (n, input) in Self.inputs.enumerated() {
            let hint = LocalCleanup.structuralReason(input)
            if hint != nil { hinted += 1 }
            var verdicts: [String] = [], outs: [String] = []
            for repair in [false, true] {
                let out = await AICleanup.clean(input, repair: repair).text ?? ""
                let verdict: String
                if out.isEmpty { verdict = "empty" }
                else if !LocalCleanup.looksFaithful(input: input, output: out, minRecall: 0.5, maxGrowth: 3) { verdict = "recall" }
                else if let why = CleanupGate.rejection(input: input, output: out, repairHint: repair) { verdict = why.rawValue }
                else { verdict = out == input ? "unchanged" : "fixed" }
                verdicts.append(verdict); outs.append(out)
            }
            if verdicts[0] == "fixed" { fixedGeneric += 1 }
            if verdicts[1] == "fixed" { fixedRepair += 1 }
            // What the pipeline actually produces, routing and fallbacks included.
            UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
            let pipe = await LocalCleanup.applyWithPath(to: input)
            let pipeVerdict = pipe.text == input ? "unchanged" : (pipe.path == .ai ? "fixed" : "rules")
            if pipeVerdict == "fixed" { fixedPipeline += 1 }
            print("RB|\(n)|\(hint ?? "-")|\(verdicts[0])|\(outs[0])|\(verdicts[1])|\(outs[1])|\(pipeVerdict)|\(pipe.text)|\(input)")
        }
        print("RB|tally|hinted \(hinted)/\(Self.inputs.count)|generic fixed \(fixedGeneric)|repair fixed \(fixedRepair)|pipeline fixed \(fixedPipeline)")
    }
}
