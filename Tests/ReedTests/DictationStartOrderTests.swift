import XCTest
@testable import Reed

/// Review 2026-09-06: a second hotkey while a press is live touches nothing.
/// The model refusal used to run before the busy guard, so a press that was
/// admitted with the model present could be flipped to `.error` mid-recording
/// by a second press once the model went missing or a download began.
@MainActor
final class DictationStartOrderTests: XCTestCase {
    private var savedOnboarding: Any?

    override func setUp() {
        super.setUp()
        savedOnboarding = UserDefaults.standard.object(forKey: OnboardingState.completedKey)
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
    }

    override func tearDown() {
        ModelStore.speechModelInstalledOverride = nil
        if let savedOnboarding { UserDefaults.standard.set(savedOnboarding, forKey: OnboardingState.completedKey) }
        else { UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey) }
        super.tearDown()
    }

    func testASecondStartWhileRecordingLeavesThePressAlone() async {
        let coordinator = Coordinator()
        coordinator.state = .recording
        ModelStore.speechModelInstalledOverride = false   // the refusal WOULD fire for a fresh press
        XCTAssertNotNil(coordinator.speechModelRefusal(), "precondition: this press would be refused if it were new")
        await coordinator.start()
        XCTAssertEqual(coordinator.state, .recording, "the live press keeps its state")
        XCTAssertNil(coordinator.activeError, "and no error is raised on it")
    }

    func testAFreshStartWithoutTheModelIsRefusedBeforeAnythingIsCaptured() async {
        let coordinator = Coordinator()
        ModelStore.speechModelInstalledOverride = false
        await coordinator.start()
        guard case .error = coordinator.state else { return XCTFail("expected the refusal, got \(coordinator.state)") }
        XCTAssertNotNil(coordinator.activeError)
    }
}
