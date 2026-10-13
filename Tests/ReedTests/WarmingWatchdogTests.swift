import AppKit
import XCTest
@testable import Reed

/// The warming watchdog's clock (2026-10-12): with AirPods as the default
/// devices, a cold start spent 1.5-5 s before the mic started, and the 2 s
/// budget, counted from the press, failed every first press with
/// "Microphone didn't start" about 0.1 s before capture armed. The frames
/// budget now starts when the mic has started; a start that never returns
/// is caught by its own, longer cap. `recorderStartForTesting` stands in for
/// the slow engine start.
@MainActor
final class WarmingWatchdogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey)
        super.tearDown()
    }

    private func isWarming(_ coordinator: Coordinator) -> Bool {
        if case .warming = coordinator.state { return true }
        return false
    }

    private func isError(_ coordinator: Coordinator) -> Bool {
        if case .error = coordinator.state { return true }
        return false
    }

    /// Waits up to `seconds` for `condition`, letting main-actor work run.
    private func waitFor(_ seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The reported failure: a start slower than the frames budget is not a
    /// dead mic; the frames budget still applies once it has started.
    func testASlowStartIsNotADeadMicButSilenceAfterItIs() async {
        let coordinator = Coordinator()
        coordinator.warmingBudgetsForTesting = (start: 3_000_000_000, frames: 200_000_000)
        coordinator.recorderStartForTesting = { _ in try await Task.sleep(nanoseconds: 500_000_000) }
        coordinator.state = .warming
        coordinator.startWarmingWatchdog(forStart: true)

        await coordinator.startRecorder(generation: coordinator.pressGeneration)

        XCTAssertTrue(isWarming(coordinator), "a start slower than the frames budget was called a dead mic")
        await waitFor(2) { isError(coordinator) }
        XCTAssertTrue(isError(coordinator), "no frames after the mic started must still fail")
        coordinator.warmingWatchdog?.cancel()
    }

    func testAStartThatNeverReturnsStillFails() async {
        let coordinator = Coordinator()
        coordinator.warmingBudgetsForTesting = (start: 300_000_000, frames: 5_000_000_000)
        coordinator.recorderStartForTesting = { _ in try await Task.sleep(nanoseconds: 30_000_000_000) }
        coordinator.state = .warming
        coordinator.startWarmingWatchdog(forStart: true)

        let start = Task { await coordinator.startRecorder(generation: coordinator.pressGeneration) }
        await waitFor(2) { isError(coordinator) }

        XCTAssertTrue(isError(coordinator), "a hung start was never reported")
        start.cancel()
        coordinator.warmingWatchdog?.cancel()
    }

    /// Sibling: the mid-press restart after an interrupted capture is a cold
    /// start too, under the same clock.
    func testASlowCaptureRestartIsNotADeadMic() async {
        let coordinator = Coordinator()
        coordinator.warmingBudgetsForTesting = (start: 3_000_000_000, frames: 200_000_000)
        var restarted = false
        coordinator.recorderStartForTesting = { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            restarted = true
        }
        coordinator.state = .recording

        coordinator.handleCaptureInterrupted()
        await waitFor(2) { restarted }

        XCTAssertTrue(restarted)
        XCTAssertTrue(isWarming(coordinator), "a slow restart was called a dead mic")
        await waitFor(2) { isError(coordinator) }
        XCTAssertTrue(isError(coordinator), "no frames after the restart must still fail")
        coordinator.warmingWatchdog?.cancel()
    }
}
