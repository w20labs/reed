import XCTest
@testable import Reed

/// Bluetooth mics cannot be pinned (design: "Bluetooth mics are not pinnable").
///
/// Pinning sets `kAudioOutputUnitProperty_CurrentDevice` on Reed's own input
/// unit. A wired device always exposes a live input stream so that works; a
/// Bluetooth device only exposes one once macOS has switched it to HFP, and
/// only the SYSTEM input selection triggers that switch. Pinning AirPods in
/// A2DP yields a device that returns no audio at all — indefinitely, with no
/// error. These pin the rules that keep a user out of that dead end.
final class BluetoothPinningTests: XCTestCase {

    private func device(_ id: String, bluetooth: Bool = false, builtIn: Bool = false) -> AudioInputDevice {
        AudioInputDevice(id: id, name: id, isBuiltIn: builtIn, isBluetooth: bluetooth)
    }

    /// Isolated suite so nothing here touches the real user defaults.
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "reed.tests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - the stale-pin migration

    func testPinToAConnectedBluetoothDeviceIsCleared() {
        // The dead end this whole change exists to close: builds before
        // 2026-07-28 let users pick AirPods here, and the picker that set the
        // pin no longer lists Bluetooth — so without this the pin is
        // unreachable AND permanently silent.
        let defaults = freshDefaults()
        defaults.set("airpods-uid", forKey: AudioInputDevice.preferredUIDDefaultsKey)

        let uid = AudioInputDevice.loadPreferredUID(
            defaults: defaults,
            connected: [device("airpods-uid", bluetooth: true)]
        )

        XCTAssertNil(uid, "a Bluetooth pin can only record silence — it must not survive launch")
        XCTAssertNil(defaults.string(forKey: AudioInputDevice.preferredUIDDefaultsKey),
                     "and it must be erased, not just ignored for this session")
    }

    func testPinToADisconnectedDeviceSurvives() {
        // Absent from the list normally means "unplugged right now", not
        // "unusable". Clearing it would silently lose a USB mic preference
        // every time the user undocked.
        let defaults = freshDefaults()
        defaults.set("usb-mic", forKey: AudioInputDevice.preferredUIDDefaultsKey)

        let uid = AudioInputDevice.loadPreferredUID(
            defaults: defaults,
            connected: [device("built-in", builtIn: true)]
        )

        XCTAssertEqual(uid, "usb-mic", "an unplugged device should still be the preference")
        XCTAssertEqual(defaults.string(forKey: AudioInputDevice.preferredUIDDefaultsKey), "usb-mic")
    }

    func testPinToAConnectedWiredDeviceSurvives() {
        let defaults = freshDefaults()
        defaults.set("usb-mic", forKey: AudioInputDevice.preferredUIDDefaultsKey)

        let uid = AudioInputDevice.loadPreferredUID(
            defaults: defaults,
            connected: [device("usb-mic"), device("built-in", builtIn: true)]
        )

        XCTAssertEqual(uid, "usb-mic", "external mics pin fine — that is the whole distinction")
    }

    func testNoPinReadsAsSystemDefault() {
        let defaults = freshDefaults()
        XCTAssertNil(AudioInputDevice.loadPreferredUID(defaults: defaults, connected: []))
    }

    func testEmptyPinReadsAsSystemDefault() {
        // "" is the picker's tag for System Default; it must not be treated
        // as a UID that failed to resolve.
        let defaults = freshDefaults()
        defaults.set("", forKey: AudioInputDevice.preferredUIDDefaultsKey)
        XCTAssertNil(AudioInputDevice.loadPreferredUID(defaults: defaults, connected: []))
    }

    // MARK: - what the picker is allowed to offer

    func testTheNoticeOffersTheWayOut() {
        // The first version explained the limitation accurately and then left
        // the reader with nowhere to go.
        XCTAssertTrue(MenuNotice.bluetooth.detail.contains("built-in"),
                      "the notice should still name the faster alternative")
    }
}

/// The proactive nudge's rate limit (design: "3 · The proactive nudge").
///
/// Frequency is the whole design: every-dictation trains the user to dismiss
/// unread, once-ever is missed by anyone away from the keyboard.
final class BluetoothNudgePolicyTests: XCTestCase {

    private func policy(_ name: String = #function) -> BluetoothNudgePolicy {
        let suite = "reed.tests.nudge.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return BluetoothNudgePolicy(defaults: UserDefaults(suiteName: suite)!)
    }

    func testFiresTheFirstTime() {
        XCTAssertTrue(policy().shouldShow())
    }

    func testDoesNotFireTwiceWithinTheHour() {
        let p = policy()
        let now = Date()
        p.recordShown(now: now)
        XCTAssertFalse(p.shouldShow(now: now.addingTimeInterval(59 * 60)),
                       "a second nudge 59 minutes later is nagging")
    }

    func testFiresAgainAfterTheHour() {
        let p = policy()
        let now = Date()
        p.recordShown(now: now)
        XCTAssertTrue(p.shouldShow(now: now.addingTimeInterval(BluetoothNudgePolicy.interval + 1)),
                      "someone who was away from the keyboard should still get told")
    }

    func testDismissalIsPermanent() {
        let p = policy()
        p.suppressForever()
        XCTAssertFalse(p.shouldShow(now: Date().addingTimeInterval(86_400 * 365)),
                       "a user who only owns AirPods has heard us — for the life of the app")
    }

    func testDismissalOutranksAnExpiredWindow() {
        // Ordering guard: the hour having elapsed must not resurrect a nudge
        // the user permanently dismissed.
        let p = policy()
        let now = Date()
        p.recordShown(now: now)
        p.suppressForever()
        XCTAssertFalse(p.shouldShow(now: now.addingTimeInterval(BluetoothNudgePolicy.interval + 1)))
    }

    func testABackwardsClockDoesNotLockTheNudgeOut() {
        // Timezone change or NTP correction: without the guard, a timestamp
        // in the future silences the nudge until wall time catches up.
        let p = policy()
        let now = Date()
        p.recordShown(now: now.addingTimeInterval(86_400))
        XCTAssertTrue(p.shouldShow(now: now))
    }
}
