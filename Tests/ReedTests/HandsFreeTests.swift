import AppKit
import KeyboardShortcuts
import XCTest
@testable import Reed

/// Hands-free dictation (P17, DECIDED 2026-10-11): the double-tap gesture on
/// the bare-modifier hold, the locked session's finish / Esc / chord rules,
/// and the five-minute limit. Tap timing runs on an injected clock, so every
/// case states its exact durations instead of racing a real one.
@MainActor
final class HandsFreeTests: XCTestCase {
    private let trigger: NSEvent.ModifierFlags = [.control, .option]

    private final class Recorder {
        var starts = 0
        var stops: [Bool] = []
        var locks = 0
        var startsLocked = 0
        var finishes = 0
        var escapes = 0
    }

    /// A monitor on a manual clock. `armDelay` 0.01 lets a press go live
    /// after `waitForArm`; a huge one keeps every press inside the delay.
    private func makeMonitor(clock: @escaping () -> TimeInterval, armDelay: TimeInterval = 0.01,
                             locked: @escaping () -> Bool = { false }) -> (ModifierHoldMonitor, Recorder) {
        let monitor = ModifierHoldMonitor(trigger: trigger, armDelay: armDelay, now: clock)
        let events = Recorder()
        monitor.onStart = { events.starts += 1 }
        monitor.onStop = { events.stops.append($0) }
        monitor.onLock = { events.locks += 1 }
        monitor.onStartLocked = { events.startsLocked += 1 }
        monitor.onFinish = { events.finishes += 1 }
        monitor.onEscape = { events.escapes += 1 }
        monitor.isLocked = locked
        return (monitor, events)
    }

    private func waitForArm() async {
        let done = expectation(description: "arm delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
    }

    /// The way a keyboard delivers ⌃⌥: ⌃ first, then ⌥ joins.
    private func press(_ monitor: ModifierHoldMonitor) {
        monitor.flagsChanged([.control])
        monitor.flagsChanged(trigger)
    }

    /// The way it lifts: ⌃ up first (⌥ alone remains), then everything.
    private func release(_ monitor: ModifierHoldMonitor) {
        monitor.flagsChanged([.option])
        monitor.flagsChanged([])
    }

    // MARK: - the gesture

    func testTwoQuickTapsLockWithOneStartAndNoStop() {
        var time: TimeInterval = 100
        let (monitor, events) = makeMonitor(clock: { time }, armDelay: 60)
        press(monitor); time += 0.10; release(monitor)
        time += 0.20
        press(monitor); time += 0.10; release(monitor)

        XCTAssertEqual(events.startsLocked, 1, "the mic goes live once, already locked, in one call")
        XCTAssertEqual(events.starts + events.locks, 0, "never a start and a lock that must land in order")
        XCTAssertEqual(events.stops, [], "a lock is not a release: nothing may stop or transcribe")
    }

    func testTapsThatReachCaptureStillLockAndTheFirstIsDiscardedSilently() async {
        var time: TimeInterval = 100
        let (monitor, events) = makeMonitor(clock: { time })
        press(monitor); await waitForArm(); time += 0.20; release(monitor)
        XCTAssertEqual(events.stops, [true], "a tap is never a dictation: its take is discarded, not transcribed")

        time += 0.30
        press(monitor); await waitForArm(); time += 0.20; release(monitor)
        XCTAssertEqual(events.starts, 2)
        XCTAssertEqual(events.locks, 1)
        XCTAssertEqual(events.stops, [true], "the second tap locks; it must not also stop")
    }

    func testAHoldStillTranscribes() async {
        var time: TimeInterval = 100
        let (monitor, events) = makeMonitor(clock: { time })
        press(monitor); await waitForArm(); time += 1.5; release(monitor)
        XCTAssertEqual(events.stops, [false])
        XCTAssertEqual(events.locks, 0)
    }

    func testATapThenAHoldIsAnOrdinaryHold() async {
        var time: TimeInterval = 100
        let (monitor, events) = makeMonitor(clock: { time })
        press(monitor); time += 0.10; release(monitor)
        time += 0.20
        press(monitor); await waitForArm(); time += 2.0; release(monitor)
        XCTAssertEqual(events.locks, 0, "a second press held past a tap is a hold, not a lock")
        XCTAssertEqual(events.stops, [false])
    }

    func testASlowSecondTapDoesNotLock() async {
        var time: TimeInterval = 100
        let (monitor, events) = makeMonitor(clock: { time }, armDelay: 60)
        press(monitor); time += 0.10; release(monitor)
        time += DoubleTapDetector.gapMax + 0.05
        press(monitor); time += 0.10; release(monitor)
        XCTAssertEqual(events.locks + events.startsLocked, 0)
        XCTAssertEqual(events.starts, 0, "two lone taps start nothing")
    }

    func testTypingBetweenTapsBreaksTheGesture() {
        var time: TimeInterval = 100
        let (monitor, events) = makeMonitor(clock: { time }, armDelay: 60)
        press(monitor); time += 0.10; release(monitor)
        monitor.keyDown(keyCode: 0)  // "a"
        time += 0.10
        press(monitor); time += 0.10; release(monitor)
        XCTAssertEqual(events.locks + events.startsLocked, 0)
    }

    func testAThirdQuickTapDoesNotLockAgain() {
        var time: TimeInterval = 100
        let (monitor, events) = makeMonitor(clock: { time }, armDelay: 60)
        for _ in 0..<3 {
            press(monitor); time += 0.10; release(monitor); time += 0.10
        }
        XCTAssertEqual(events.locks + events.startsLocked, 1, "the second tap closes the window; a third starts a new sequence")
    }

    // MARK: - the locked session

    func testATapWhileLockedFinishesAndStartsNothing() {
        let (monitor, events) = makeMonitor(clock: { 100 }, armDelay: 60, locked: { true })
        press(monitor); release(monitor)
        XCTAssertEqual(events.finishes, 1)
        XCTAssertEqual(events.starts, 0)
        XCTAssertEqual(events.stops, [])
    }

    func testAShortcutWhileLockedDoesNotFinish() {
        let (monitor, events) = makeMonitor(clock: { 100 }, armDelay: 60, locked: { true })
        press(monitor)
        monitor.keyDown(keyCode: 8)  // ⌃⌥C — an app shortcut, keys are free
        release(monitor)
        XCTAssertEqual(events.finishes, 0)

        press(monitor); release(monitor)
        XCTAssertEqual(events.finishes, 1, "after a full release the next clean tap finishes")
    }

    func testAnExtraModifierWhileLockedDoesNotFinish() {
        let (monitor, events) = makeMonitor(clock: { 100 }, armDelay: 60, locked: { true })
        press(monitor)
        monitor.flagsChanged([.control, .option, .command])
        monitor.flagsChanged([])
        XCTAssertEqual(events.finishes, 0)
    }

    func testTypingWhileLockedEndsNothing() {
        let (monitor, events) = makeMonitor(clock: { 100 }, locked: { true })
        monitor.keyDown(keyCode: 0)
        monitor.keyDown(keyCode: 49)
        XCTAssertEqual(events.stops, [])
        XCTAssertEqual(events.finishes + events.escapes, 0)
    }

    func testEscDiscardsOnlyALockedSession() {
        var locked = false
        let (monitor, events) = makeMonitor(clock: { 100 }, locked: { locked })
        monitor.keyDown(keyCode: ModifierHoldMonitor.escapeKeyCode)
        XCTAssertEqual(events.escapes, 0, "Esc outside hands-free belongs to the app alone")
        locked = true
        monitor.keyDown(keyCode: ModifierHoldMonitor.escapeKeyCode)
        XCTAssertEqual(events.escapes, 1)
    }

    /// The coordinator is the authority on the lock: once its session ends
    /// (limit, lost mic, error), the next press is an ordinary one.
    func testAnEndedSessionIsNotStale() async {
        var locked = true
        let (monitor, events) = makeMonitor(clock: { 100 }, locked: { locked })
        locked = false
        press(monitor); await waitForArm()
        XCTAssertEqual(events.starts, 1)
        XCTAssertEqual(events.finishes, 0)
    }

    // MARK: - the coordinator

    func testLockNeedsALiveCapture() {
        let coordinator = Coordinator()
        coordinator.lockHandsFree()
        XCTAssertFalse(coordinator.handsFree, "a refused start has nothing to lock")
        coordinator.state = .recording
        coordinator.lockHandsFree()
        XCTAssertTrue(coordinator.isHandsFreeLive)
    }

    /// The production start-locked path: a press refused without a state
    /// change (the last dictation is still transcribing) captures nothing,
    /// so it must leave no lock behind — no state change means nothing else
    /// would clear it, and the next ordinary hold would inherit it.
    func testARefusedLockedStartLeavesNoLock() async {
        let coordinator = Coordinator()
        coordinator.state = .transcribing
        await coordinator.start(handsFree: true)
        XCTAssertEqual(coordinator.state, .transcribing, "precondition: the busy guard refused the press")
        XCTAssertFalse(coordinator.handsFree)
    }

    func testLeavingCaptureEndsTheSession() {
        let coordinator = Coordinator()
        coordinator.state = .recording
        coordinator.lockHandsFree()
        coordinator.recordingLimitNear = true
        coordinator.state = .transcribing
        XCTAssertFalse(coordinator.handsFree)
        XCTAssertFalse(coordinator.recordingLimitNear)
    }

    func testEscShowsDiscardedAndWritesNothing() {
        let coordinator = Coordinator()
        coordinator.state = .recording
        coordinator.discardHandsFree()
        XCTAssertEqual(coordinator.state, .recording, "Esc during a hold is not a discard")

        coordinator.lockHandsFree()
        coordinator.discardHandsFree()
        XCTAssertEqual(coordinator.state, .notice("Discarded"))
        XCTAssertFalse(coordinator.handsFree)
    }

    /// Waits for a condition on the main actor, bounded: the main queue can
    /// be busy for a while after Coordinator() is built, so a fixed sleep
    /// would race it.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testTheWarningShowsBeforeTheLimit() async throws {
        let coordinator = Coordinator()
        coordinator.recordingLimitSchedule = (warn: 0.02, finish: 60)
        coordinator.state = .recording
        coordinator.armRecordingLimit(generation: coordinator.pressGeneration)
        try await eventually { coordinator.recordingLimitNear }
        XCTAssertTrue(coordinator.recordingLimitNear, "30 s left must show before the limit")
        XCTAssertEqual(coordinator.state, .recording, "the warning keeps listening")
        coordinator.recordingLimitTask?.cancel()
    }

    func testAtTheLimitThePressFinishesOnItsOwn() async {
        let coordinator = Coordinator()
        coordinator.recordingLimitSchedule = (warn: 0.01, finish: 0.02)
        coordinator.state = .recording
        coordinator.lockHandsFree()
        // A short take that is otherwise healthy: the release path drops it
        // quietly to idle, which is what proves the limit ran it.
        coordinator.realSignalConfirmedForCurrentRecording = true
        coordinator.holdStartedAt = Date()
        coordinator.armRecordingLimit(generation: coordinator.pressGeneration)
        await coordinator.recordingLimitTask?.value

        XCTAssertEqual(coordinator.state, .idle, "at the limit the press finishes on its own")
        XCTAssertFalse(coordinator.handsFree)
        XCTAssertFalse(coordinator.recordingLimitNear)
    }

    /// The timer outlives its press: it must never warn or finish the next
    /// one. Awaits the timer to its end, so a pass means it ran and refused.
    func testALimitTimerCannotTouchTheNextPress() async {
        let coordinator = Coordinator()
        coordinator.recordingLimitSchedule = (warn: 0.01, finish: 0.02)
        coordinator.state = .recording
        coordinator.armRecordingLimit(generation: coordinator.pressGeneration)
        coordinator.pressGeneration &+= 1  // the press ended; a new one is recording
        await coordinator.recordingLimitTask?.value

        XCTAssertEqual(coordinator.state, .recording)
        XCTAssertFalse(coordinator.recordingLimitNear)
    }

    /// Same rule after the warning: a press that ended between 4:30 and 5:00
    /// must not have its successor finished at 5:00.
    func testALimitTimerPastItsWarningCannotFinishTheNextPress() async throws {
        let coordinator = Coordinator()
        coordinator.recordingLimitSchedule = (warn: 0.01, finish: 0.3)
        coordinator.state = .recording
        coordinator.armRecordingLimit(generation: coordinator.pressGeneration)
        try await eventually { coordinator.recordingLimitNear }
        XCTAssertTrue(coordinator.recordingLimitNear)
        coordinator.pressGeneration &+= 1
        await coordinator.recordingLimitTask?.value

        XCTAssertEqual(coordinator.state, .recording)
    }

    // MARK: - the recorded combo

    /// While locked, the combo finishes and starts nothing: the press only
    /// marks the finish, the release runs the release path.
    func testTheComboFinishesALockedSessionWithoutStartingOne() async throws {
        let coordinator = Coordinator()
        coordinator.state = .recording
        coordinator.lockHandsFree()
        coordinator.realSignalConfirmedForCurrentRecording = true
        coordinator.holdStartedAt = Date()
        coordinator.shortcutPressed()
        XCTAssertEqual(coordinator.shortcutPress?.finishes, true)
        XCTAssertEqual(coordinator.state, .recording, "the press itself changes nothing")
        coordinator.shortcutReleased()
        try await eventually { coordinator.state == .idle }
        XCTAssertEqual(coordinator.state, .idle, "the release finishes the session")
    }

    // MARK: - the timing rules

    func testDetectorTimingRules() {
        var taps = DoubleTapDetector()
        XCTAssertFalse(taps.pressIsSecondTap(at: 10), "nothing before a first tap")
        taps.released(pressedAt: 10, releasedAt: 10 + DoubleTapDetector.tapMax, wasSecondTap: false)
        XCTAssertTrue(taps.pressIsSecondTap(at: 10.25 + DoubleTapDetector.gapMax - 0.001), "a press inside the gap is the second tap")
        XCTAssertFalse(taps.pressIsSecondTap(at: 10.25 + DoubleTapDetector.gapMax + 0.01))

        taps.released(pressedAt: 20, releasedAt: 20.3, wasSecondTap: false)
        XCTAssertFalse(taps.pressIsSecondTap(at: 20.4), "a hold opens no window")

        taps.released(pressedAt: 30, releasedAt: 30.1, wasSecondTap: false)
        taps.reset()
        XCTAssertFalse(taps.pressIsSecondTap(at: 30.2), "a reset closes the window")
    }

    // MARK: - review 2026-10-11

    /// A capture retry passes the press back through warming. Caught there
    /// at 4:30, the timer used to exit for good and the capture ran on past
    /// 5:00.
    func testARetryAtTheWarningKeepsTheDeadline() async throws {
        let coordinator = Coordinator()
        coordinator.state = .recording
        coordinator.lockHandsFree()
        coordinator.recordingLimitSchedule = (warn: 0.02, finish: 0.3)
        coordinator.armRecordingLimit(generation: coordinator.pressGeneration)
        coordinator.state = .warming  // the retry; pressGeneration unchanged
        try await eventually { coordinator.recordingLimitNear }
        XCTAssertTrue(coordinator.recordingLimitNear, "a retrying press is still the press: it warns")
        coordinator.state = .recording
        coordinator.realSignalConfirmedForCurrentRecording = true
        coordinator.holdStartedAt = Date()
        await coordinator.recordingLimitTask?.value
        XCTAssertEqual(coordinator.state, .idle, "the recovered press still finishes at its deadline")
    }

    func testARetryAtTheLimitStillFinishes() async throws {
        let coordinator = Coordinator()
        coordinator.state = .recording
        coordinator.lockHandsFree()
        coordinator.recordingLimitSchedule = (warn: 0.01, finish: 0.1)
        coordinator.armRecordingLimit(generation: coordinator.pressGeneration)
        try await eventually { coordinator.recordingLimitNear }
        coordinator.state = .warming
        coordinator.holdStartedAt = Date()
        await coordinator.recordingLimitTask?.value
        XCTAssertEqual(coordinator.state, .idle, "the deadline stops a press even while its retry is warming")
    }

    /// The combo keeps its own tap sequence; typing must break it exactly as
    /// it breaks the hold's. Drives the production handlers; the busy state
    /// refuses the real start.
    func testTypingBreaksTheComboSequence() {
        let coordinator = Coordinator()
        coordinator.state = .transcribing
        coordinator.shortcutPressed()
        coordinator.shortcutReleased()
        coordinator.holdMonitor.keyDown(keyCode: 0)  // "a"
        coordinator.shortcutPressed()
        XCTAssertEqual(coordinator.shortcutPress?.isSecondTap, false)
        coordinator.shortcutReleased()
    }

    func testAShortcutChangeBreaksTheComboSequence() {
        let coordinator = Coordinator()
        coordinator.state = .transcribing
        coordinator.shortcutPressed()
        coordinator.shortcutReleased()
        NotificationCenter.default.post(name: PushToTalkTrigger.didChange, object: nil)
        coordinator.shortcutPressed()
        XCTAssertEqual(coordinator.shortcutPress?.isSecondTap, false)
        coordinator.shortcutReleased()
    }

    /// The combo's own key event must NOT count as typing, or no second tap
    /// could ever land if the global monitor sees it.
    func testTheComboItselfDoesNotBreakItsSequence() {
        let saved = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        defer { KeyboardShortcuts.setShortcut(saved, for: .toggleDictation) }
        let combo = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
        KeyboardShortcuts.setShortcut(combo, for: .toggleDictation)
        let coordinator = Coordinator()
        coordinator.state = .transcribing
        coordinator.shortcutPressed()
        coordinator.shortcutReleased()
        coordinator.holdMonitor.keyDown(keyCode: UInt16(combo.carbonKeyCode), modifiers: [.control, .option])
        coordinator.shortcutPressed()
        XCTAssertEqual(coordinator.shortcutPress?.isSecondTap, true)
        coordinator.shortcutReleased()
        // The same letter without the combo's modifiers is ordinary typing.
        coordinator.shortcutPressed()
        coordinator.shortcutReleased()
        coordinator.holdMonitor.keyDown(keyCode: UInt16(combo.carbonKeyCode))
        coordinator.shortcutPressed()
        XCTAssertEqual(coordinator.shortcutPress?.isSecondTap, false)
        coordinator.shortcutReleased()
    }

    /// The hint names the live shortcut: a retarget mid-session must move it.
    func testTheFinishHintFollowsAShortcutChange() async throws {
        let saved = UserDefaults.standard.object(forKey: PushToTalkTrigger.defaultsKey)
        let savedCombo = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: PushToTalkTrigger.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: PushToTalkTrigger.defaultsKey) }
            KeyboardShortcuts.setShortcut(savedCombo, for: .toggleDictation)
        }
        UserDefaults.standard.set(PushToTalkTrigger.controlOption.rawValue, forKey: PushToTalkTrigger.defaultsKey)
        let coordinator = Coordinator()
        let overlay = OverlayController()
        overlay.attach(to: coordinator)
        coordinator.state = .recording
        coordinator.lockHandsFree()
        try await eventually { overlay.viewModel.handsFreeHint != nil }
        XCTAssertEqual(overlay.viewModel.handsFreeHint, "tap ⌃⌥ to finish")

        UserDefaults.standard.set(PushToTalkTrigger.controlCommand.rawValue, forKey: PushToTalkTrigger.defaultsKey)
        NotificationCenter.default.post(name: PushToTalkTrigger.didChange, object: nil)
        try await eventually { overlay.viewModel.handsFreeHint == "tap ⌃⌘ to finish" }
        XCTAssertEqual(coordinator.holdMonitor.currentTrigger, [.control, .command])
        XCTAssertTrue(coordinator.isHandsFreeLive)
        XCTAssertEqual(overlay.viewModel.handsFreeHint, "tap ⌃⌘ to finish")

        // Hold → recorded combo, the same way the recorder field does it.
        let combo = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
        KeyboardShortcuts.setShortcut(combo, for: .toggleDictation)
        PushToTalkTrigger.custom.apply()
        try await eventually { overlay.viewModel.handsFreeHint == "tap \(combo.description) to finish" }
        XCTAssertEqual(overlay.viewModel.handsFreeHint, "tap \(combo.description) to finish")
    }

    // MARK: - the HUD

    func testThePillNamesTheSession() {
        let model = OverlayViewModel()
        model.state = .recording
        XCTAssertEqual(OverlayView.labelForTesting(model), "Listening")
        model.handsFreeHint = "tap ⌃⌥ to finish"
        XCTAssertEqual(OverlayView.labelForTesting(model), "Hands-free")
        model.recordingLimitNear = true
        XCTAssertEqual(OverlayView.labelForTesting(model), "30 s left")
    }
}
