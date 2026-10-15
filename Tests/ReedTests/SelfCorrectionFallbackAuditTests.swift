import XCTest
@testable import Reed

final class SelfCorrectionFallbackAuditTests: XCTestCase {
    func testACueOnlyDeletionCannotMakeTwoOptionsLookLikeOne() {
        let input = "Our team has five, I mean, six open roles."
        let output = "Our team has five six open roles."
        let verdict = CleanupGate.rejection(input: input, output: output, repairHint: false)
        print("CUE_ONLY_AUDIT|\(verdict?.rawValue ?? "accepted")")
        XCTAssertNotNil(verdict)
    }
    @available(macOS 26.0, *)
    func testTheProductionLoopRefusesCueOnlyDeletion() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("availability for controlled text-only model reply") }
        let previousTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let previousOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = previousOverride
            if let previousTier { UserDefaults.standard.set(previousTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let harmful = "Our team has five six open roles."
        LocalCleanup.modelCallOverrideForTests = { _, _ in .text(harmful) }
        let result = await LocalCleanup.applyWithPath(to: "Our team has five, I mean, six open roles.")
        print("CUE_ONLY_PRODUCTION|\(result.path.rawValue)|\(result.text)")
        XCTAssertNotEqual(result.text, harmful)
    }
    @available(macOS 26.0, *)
    func testARejectedCorrectionMustKeepItsCue() async throws {
        guard AICleanup.isAvailable else { throw XCTSkip("availability for controlled text-only model reply") }
        let previousTier = UserDefaults.standard.object(forKey: LocalCleanup.tierKey)
        let previousOverride = LocalCleanup.modelCallOverrideForTests
        defer {
            LocalCleanup.modelCallOverrideForTests = previousOverride
            if let previousTier { UserDefaults.standard.set(previousTier, forKey: LocalCleanup.tierKey) }
            else { UserDefaults.standard.removeObject(forKey: LocalCleanup.tierKey) }
        }
        LocalCleanup.setTier(.ai)
        let cases = [
            ("Our team has five, I mean, six open roles.", "Our team has five open roles."),
            ("Please call Anna, I mean, please email Anna.", "Please call Anna.")
        ]
        for (input, rejectedProposal) in cases {
            LocalCleanup.modelCallOverrideForTests = { _, _ in .text(rejectedProposal) }
            let result = await LocalCleanup.applyWithPath(to: input)
            print("FALLBACK_AUDIT|\(input)|\(result.reason ?? "-")|\(result.text)")
            XCTAssertEqual(result.text, input, "A refused correction must remain understandable")
        }
    }
}
