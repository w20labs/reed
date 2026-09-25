import XCTest
@testable import Reed

/// Finding 5 (2026-08-29): the cleanup model lowercases proper nouns in
/// chunks that open mid-sentence (resplit fragments of a run-on) —
/// "wednesday", "sarah", "macbooks". Measure: long run-on inputs with known
/// proper nouns through LocalCleanup.apply; count the ones that lost their
/// capital. Gated: REED_CASE_BENCH=1. Lines: CB|<n>|<lost>/<total>|<lost words>|<text>
final class CaseBenchTests: XCTestCase {
    static let inputs: [(String, [String])] = [
        ("So I was thinking about the launch plan and honestly the more I look at it the more I think we should move the date because the onboarding flow still has that issue where the model download stalls on slow connections and the support team hasn't been trained on the new settings pane yet and marketing wants another week for the video and if we ship on Friday we're going to spend the whole weekend answering emails about the same three problems which nobody wants so my proposal is we push it to the following Wednesday give engineering the extra days to fix the download retry add the tooltip that Dana asked for and run one more round of testing on the older MacBooks that people keep reporting problems with and then we announce it properly with the blog post and the demo video ready to go instead of scrambling at the last minute like we did last time.",
         ["Friday", "Wednesday", "Dana", "MacBooks"]),
        ("Nadia reproduced it twice on the office Wi-Fi and once on her phone's hotspot so it's not one machine and Toby thinks it is the retry logic in the download controller and he wants two days to fix it properly rather than patching it and Marketing also wants another week for the launch video and Support hasn't been trained on the new Settings pane yet so my proposal is that we move the date from Friday the 12th to Wednesday the 17th and ask Robin to send the revised timeline to everyone in London and Berlin by Monday.",
         ["Nadia", "Wi-Fi", "Toby", "Friday", "Wednesday", "Robin", "London", "Berlin", "Monday"]),
        ("Tell Dana and Felix that the GitHub branch for the iPhone build is ready and that the Riverside office wants the invoice by Thursday afternoon and that Dr. Okoro will join the call from Paris if the API tests pass on the older MacBooks before Friday.",
         ["Dana", "Felix", "GitHub", "iPhone", "Riverside", "Thursday", "Okoro", "Paris", "API", "MacBooks", "Friday"])
    ]

    @MainActor
    func testProperNounsSurviveResplit() async throws {
        guard ProcessInfo.processInfo.environment["REED_CASE_BENCH"] == "1" else { throw XCTSkip("set REED_CASE_BENCH=1") }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else { throw XCTSkip("no Foundation Models") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        defer {
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        UserDefaults.standard.set(LocalCleanupTier.ai.rawValue, forKey: LocalCleanup.tierKey)
        AICleanup.prewarm(); _ = await AICleanup.clean("warm up")
        var lostTotal = 0, total = 0
        for (n, (input, nouns)) in Self.inputs.enumerated() {
            let out = await LocalCleanup.apply(to: input)
            let words = Set(out.split { !$0.isLetter && $0 != "-" }.map(String.init))
            let lost = nouns.filter { !words.contains($0) && words.contains($0.lowercased()) }
            lostTotal += lost.count; total += nouns.count
            print("CB|\(n)|\(lost.count)/\(nouns.count)|\(lost.joined(separator: ","))|\(out)")
        }
        print("CB|tally|\(lostTotal)/\(total) proper nouns lost their capital")
    }
}
