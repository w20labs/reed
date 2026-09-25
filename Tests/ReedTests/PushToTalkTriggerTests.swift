import AppKit
import KeyboardShortcuts
import XCTest
@testable import Reed

/// The push-to-talk recorder (`HotkeyRecorderField`) captures both directions
/// in one field: a bare-modifier hold and a full combo. The mapping from a
/// released modifier set to a stored trigger is the part that can regress
/// silently — dictation would simply stop firing — so it's pinned here.
final class PushToTalkTriggerTests: XCTestCase {
    private var savedRaw: String?
    private var savedShortcut: KeyboardShortcuts.Shortcut?

    override func setUp() {
        super.setUp()
        savedRaw = UserDefaults.standard.string(forKey: PushToTalkTrigger.defaultsKey)
        savedShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation)
    }

    override func tearDown() {
        if let savedRaw {
            UserDefaults.standard.set(savedRaw, forKey: PushToTalkTrigger.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PushToTalkTrigger.defaultsKey)
        }
        KeyboardShortcuts.setShortcut(savedShortcut, for: .toggleDictation)
        super.tearDown()
    }

    // MARK: - Released bare modifiers → hold

    func testEveryHoldPresetIsReachableFromItsModifierSet() {
        for trigger in PushToTalkTrigger.allCases where trigger.isHold {
            guard let flags = trigger.modifiers else { return XCTFail("hold without modifiers: \(trigger)") }
            XCTAssertEqual(PushToTalkTrigger.hold(matching: flags), trigger)
        }
    }

    func testFunctionAloneIsNotAHold() {
        XCTAssertNil(PushToTalkTrigger.hold(matching: [.function]))
    }

    func testNoModifiersIsNotAHold() {
        XCTAssertNil(PushToTalkTrigger.hold(matching: []))
    }

    func testSingleModifierIsNotAHold() {
        // One modifier is far too easy to hit by accident — holds are pairs
        // (or the dedicated Fn key), and everything else stays armed.
        XCTAssertNil(PushToTalkTrigger.hold(matching: [.control]))
        XCTAssertNil(PushToTalkTrigger.hold(matching: [.command]))
    }

    func testUnlistedModifierSetsAreNotHolds() {
        XCTAssertNil(PushToTalkTrigger.hold(matching: [.control, .option, .command]))
        XCTAssertNil(PushToTalkTrigger.hold(matching: [.shift, .control]))
        XCTAssertNil(PushToTalkTrigger.hold(matching: [.control, .function]))
    }

    func testCustomIsNeverAHold() {
        XCTAssertFalse(PushToTalkTrigger.custom.isHold)
        XCTAssertNil(PushToTalkTrigger.custom.modifiers)
        for flags in [NSEvent.ModifierFlags](
            [[], [.control], [.control, .option], [.control, .command], [.option, .command], [.function]]
        ) {
            XCTAssertNotEqual(PushToTalkTrigger.hold(matching: flags), .custom)
        }
    }

    // MARK: - Storage semantics

    func testApplyingAHoldPersistsItAndClearsTheRecordedShortcut() {
        KeyboardShortcuts.setShortcut(.init(.r, modifiers: [.control, .option]), for: .toggleDictation)
        PushToTalkTrigger.optionCommand.apply()
        XCTAssertEqual(PushToTalkTrigger.current, .optionCommand)
        // A hold and a recorded combo must never both be live, or dictation
        // would fire twice.
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .toggleDictation))
    }

    func testApplyingCustomKeepsTheRecordedShortcut() {
        let combo = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
        KeyboardShortcuts.setShortcut(combo, for: .toggleDictation)
        PushToTalkTrigger.custom.apply()
        XCTAssertEqual(PushToTalkTrigger.current, .custom)
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .toggleDictation), combo)
    }

    func testCurrentFallsBackToTheControlOptionHold() {
        UserDefaults.standard.removeObject(forKey: PushToTalkTrigger.defaultsKey)
        XCTAssertEqual(PushToTalkTrigger.current, .controlOption)
    }
}
