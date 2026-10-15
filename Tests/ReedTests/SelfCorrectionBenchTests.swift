import XCTest
@testable import Reed

/// Natural self-correction through the production cleanup (2026-10-14):
/// `LocalCleanup.applyWithPath` on the AI tier, so chunking, the real Apple
/// on-device model, the gate and the rules fallback all run as they do in
/// the app. Text only: no microphone, no audio hardware, no insertion.
/// Gated: REED_SELFCORR_BENCH=1. Lines:
/// SC|<set>|<id>|<kind>|<pass>|<seconds>|<path>|<reason>|<output>
final class SelfCorrectionBenchTests: XCTestCase {
    /// Prints every chunk and model attempt (SCT| lines) — the proposal and
    /// the gate's verdict, so a failure can be told apart: no proposal, a
    /// wrong one refused, or a right one refused.
    private final class Trace: CleanupObserver, @unchecked Sendable {
        let id: String
        init(id: String) { self.id = id }
        func chunkStarted(input: String, repairHint: String?) { print("SCT|\(id)|chunk|\(repairHint ?? "-")|\(input)") }
        func attempt(_ attempt: ReviewRecord.Attempt) {
            print("SCT|\(id)|attempt|\(attempt.kind)|\(attempt.verdict)|\(attempt.proposal ?? "")")
        }
        func chunkDelivered(_ text: String, outcome: ReviewRecord.ChunkOutcome, reason: String?) {}
    }

    func testSelfCorrectionAgainstTheAppleModel() async throws {
        guard ProcessInfo.processInfo.environment["REED_SELFCORR_BENCH"] == "1" else {
            throw XCTSkip("set REED_SELFCORR_BENCH=1")
        }
        guard #available(macOS 26.0, *), AICleanup.isAvailable else { throw XCTSkip("no Foundation Models") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let savedTier = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        defer {
            if let savedTier { UserDefaults.standard.set(savedTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        AICleanup.prewarm()
        _ = await AICleanup.clean("warm up")
        let sets = ProcessInfo.processInfo.environment["REED_SELFCORR_FRESH"] == "1"
            ? [("fresh", SelfCorrectionFixtures.fresh)]
            : [("research", SelfCorrectionFixtures.research), ("validation", SelfCorrectionFixtures.validation)]
        for (name, cases) in sets {
            var passed: [SelfCorrectionFixtures.Kind: Int] = [:], totals: [SelfCorrectionFixtures.Kind: Int] = [:]
            var seconds: [Double] = []
            for item in cases {
                let start = Date()
                let outcome = await LocalCleanup.$observer.withValue(Trace(id: item.id)) {
                    await LocalCleanup.applyWithPath(to: item.text)
                }
                let elapsed = Date().timeIntervalSince(start)
                seconds.append(elapsed)
                let pass = SelfCorrectionFixtures.matches(outcome.text, item.expected)
                totals[item.kind, default: 0] += 1
                if pass { passed[item.kind, default: 0] += 1 }
                print("SC|\(name)|\(item.id)|\(item.kind.rawValue)|\(pass ? "pass" : "FAIL")|"
                    + String(format: "%.2f", elapsed) + "|\(outcome.path.rawValue)|\(outcome.reason ?? "")|\(outcome.text)")
            }
            let sorted = seconds.sorted()
            let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
            print("SC|tally|\(name)|repair \(passed[.repair] ?? 0)/\(totals[.repair] ?? 0)"
                + "|preserve \(passed[.preserve] ?? 0)/\(totals[.preserve] ?? 0)"
                + String(format: "|mean %.2fs|p95 %.2fs", sorted.reduce(0, +) / Double(sorted.count), p95))
        }
    }
}
