import AppKit
import XCTest
@testable import Reed

/// State-machine tests for the bare-modifier push-to-talk hold.
///
/// These drive `flagsChanged`/`keyDown` directly with modifier sets: a real
/// hold arrives as a SEQUENCE of events (⌃ down, then ⌥ joins), and it was
/// exactly that intermediate single-modifier step that the chord-block
/// regression tripped over — the monitor had no test that pressed the
/// trigger the way a keyboard actually delivers it.
@MainActor
final class ModifierHoldMonitorTests: XCTestCase {
    private let trigger: NSEvent.ModifierFlags = [.control, .option]

    /// Waits out the arm delay by letting the main queue drain. The
    /// fulfillment timeout is generous on purpose: it bounds a HUNG main
    /// queue, not the 50 ms timer — a loaded CI runner starved this past 1 s
    /// and failed an unrelated manifest PR (2026-08-27).
    private func waitForArm() async {
        let done = expectation(description: "arm delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
    }

    /// THE REGRESSION: a real ⌃⌥ hold is two keypresses. The intermediate
    /// state (⌃ alone) is a change "away from the trigger set" with a
    /// modifier still held — which latched the chord block, so the very next
    /// event, the trigger itself, was refused. Every hold died on the way in.
    func testPressingTheTriggerOneKeyAtATimeStartsTheHold() async {
        let monitor = ModifierHoldMonitor(trigger: trigger, armDelay: 0.01)
        var started = false
        monitor.onStart = { started = true }

        monitor.flagsChanged([.control])   // ⌃ goes down first…
        monitor.flagsChanged(trigger)      // …then ⌥ joins: the hold is now held
        await waitForArm()

        XCTAssertTrue(started, "holding ⌃ then ⌥ must start dictation — that is how a keyboard delivers the hold")
    }

    /// The #246 finding this block exists for, which must keep working:
    /// joining an extra modifier ends the take, and dropping it back to the
    /// bare trigger must NOT silently start a second recording.
    func testDroppingAnExtraModifierBackToTheTriggerDoesNotRestart() async {
        let monitor = ModifierHoldMonitor(trigger: trigger, armDelay: 0.01)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1 }
        monitor.onStop = { _ in stops += 1 }

        monitor.flagsChanged([.control])
        monitor.flagsChanged(trigger)
        await waitForArm()
        XCTAssertEqual(starts, 1)

        monitor.flagsChanged([.control, .option, .command])  // ⌘ joins → take ends
        XCTAssertEqual(stops, 1)

        monitor.flagsChanged(trigger)  // ⌘ dropped, ⌃⌥ still held
        await waitForArm()
        XCTAssertEqual(starts, 1, "dropping back to the trigger mid-gesture must not start a second recording")
    }

    /// A full release is what re-arms the hold: the block clears, and the
    /// next deliberate press works normally.
    func testFullReleaseClearsTheBlockSoTheNextHoldWorks() async {
        let monitor = ModifierHoldMonitor(trigger: trigger, armDelay: 0.01)
        var starts = 0
        monitor.onStart = { starts += 1 }

        monitor.flagsChanged([.control])
        monitor.flagsChanged(trigger)
        await waitForArm()
        monitor.flagsChanged([.control, .option, .command])
        monitor.flagsChanged([])  // everything up

        monitor.flagsChanged([.control])
        monitor.flagsChanged(trigger)
        await waitForArm()
        XCTAssertEqual(starts, 2, "after a full release the hold must arm again")
    }

    /// A chord (⌃⌥C) aborts the take and stays blocked while keys are held.
    func testChordAbortsAndStaysBlockedUntilRelease() async {
        let monitor = ModifierHoldMonitor(trigger: trigger, armDelay: 0.01)
        var starts = 0
        var chordedStops = 0
        monitor.onStart = { starts += 1 }
        monitor.onStop = { chorded in if chorded { chordedStops += 1 } }

        monitor.flagsChanged([.control])
        monitor.flagsChanged(trigger)
        await waitForArm()
        monitor.keyDown()  // "C" — this was a shortcut, not dictation
        XCTAssertEqual(chordedStops, 1, "a chord must end the take as discarded")

        monitor.flagsChanged(trigger)  // key up, ⌃⌥ still down
        await waitForArm()
        XCTAssertEqual(starts, 1, "the rest of a shortcut sequence must not restart capture")

        monitor.flagsChanged([])  // full release re-arms
        monitor.flagsChanged([.control])
        monitor.flagsChanged(trigger)
        await waitForArm()
        XCTAssertEqual(starts, 2)
    }

    /// Review 2026-08-26: retargeting mid-hold (clicking a
    /// HotkeyRecorderField stands the monitor down via setTrigger(nil)) used
    /// to reset phase WITHOUT firing onStop — the mic stayed live, the HUD
    /// stuck on Listening, and the eventual release was swallowed. A live
    /// hold must end as a discarded take.
    func testRetargetingMidHoldEndsTheTakeAsDiscarded() async {
        let monitor = ModifierHoldMonitor(trigger: trigger, armDelay: 0.01)
        var starts = 0
        var stops: [Bool] = []
        monitor.onStart = { starts += 1 }
        monitor.onStop = { stops.append($0) }

        monitor.flagsChanged([.control])
        monitor.flagsChanged(trigger)
        await waitForArm()
        XCTAssertEqual(starts, 1)

        monitor.setTrigger(nil)  // a HotkeyRecorderField armed mid-hold
        XCTAssertEqual(stops, [true], "abandoning a live hold must end the take as discarded, so the mic stops")

        monitor.flagsChanged([])  // the release arrives after the stand-down
        XCTAssertEqual(stops, [true], "the late release must not fire a second stop")
    }

    /// Same hole in stop(): monitor teardown mid-hold must not orphan the
    /// live mic behind it.
    func testStopMidHoldEndsTheTakeAsDiscarded() async {
        let monitor = ModifierHoldMonitor(trigger: trigger, armDelay: 0.01)
        var stops: [Bool] = []
        monitor.onStop = { stops.append($0) }

        monitor.flagsChanged([.control])
        monitor.flagsChanged(trigger)
        await waitForArm()

        monitor.stop()
        XCTAssertEqual(stops, [true], "tearing the monitor down mid-hold must end the take")
    }

    /// Retargeting while IDLE (the common case — every arm/disarm of a
    /// recorder field calls setTrigger) must stay silent: no phantom stops.
    func testRetargetingWhileIdleFiresNothing() {
        let monitor = ModifierHoldMonitor(trigger: trigger, armDelay: 0.01)
        var stops = 0
        monitor.onStop = { _ in stops += 1 }

        monitor.setTrigger(nil)
        monitor.setTrigger(trigger)
        XCTAssertEqual(stops, 0)
    }
}
