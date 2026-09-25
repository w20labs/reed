import XCTest
@testable import Reed

/// The first-mic experience (design: "Onboarding · Microphone — Bluetooth
/// variant" + "Done — pre-warmed try-it"; decision-tree Question 3).
final class FirstMicExperienceTests: XCTestCase {

    private func device(_ id: String, bluetooth: Bool = false, builtIn: Bool = false, continuity: Bool = false) -> AudioInputDevice {
        AudioInputDevice(id: id, name: id, isBuiltIn: builtIn, isBluetooth: bluetooth, isContinuity: continuity)
    }

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "reed.tests.firstmic.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - the mic row (pure composition)

    func testPickerOffersBluetoothDefaultPlusPinnable() {
        // The Bluetooth system default appears as a choosable option (meaning
        // "no pin"), ahead of the pinnable devices.
        let airpods = device("airpods", bluetooth: true)
        let usb = device("usb")
        XCTAssertEqual(MicrophoneStep.pickerOptions(systemDefault: airpods, pinnable: [usb]), [airpods, usb])
    }

    func testPickerDoesNotDuplicateAWiredDefault() {
        // A wired system default is already in the pinnable list — listing it
        // twice would render a duplicate menu row.
        let usb = device("usb")
        XCTAssertEqual(MicrophoneStep.pickerOptions(systemDefault: usb, pinnable: [usb, device("mac", builtIn: true)]).count, 2)
    }

    func testPickerWithNoDefaultIsJustThePinnableList() {
        let usb = device("usb")
        XCTAssertEqual(MicrophoneStep.pickerOptions(systemDefault: nil, pinnable: [usb]), [usb])
    }

    func testCalloutRemedyPrefersBuiltInThenWired() {
        // The one-click remedy names the best instant-start mic: built-in
        // preferred; on Macs with none (Mac Studio, Mac mini — the hand-test
        // machine) the first WIRED mic. A Continuity iPhone mic is never
        // recommended — a mic that can walk out of the room is bad advice —
        // and with nothing else the button is omitted, sentence stands alone.
        let mac = device("mac", builtIn: true)
        let usb = device("usb")
        let iphone = device("iphone", continuity: true)
        XCTAssertEqual(MicrophoneStep.calloutFallback(pinnable: [usb, mac]), mac)
        XCTAssertEqual(MicrophoneStep.calloutFallback(pinnable: [iphone, usb]), usb)
        XCTAssertNil(MicrophoneStep.calloutFallback(pinnable: [iphone]))
    }

    // MARK: - the grant handoff

    func testGrantAutoAdvancesOnlyForNonBluetooth() {
        // The bug the stay-rule pins: grant used to advance the flow at the
        // exact instant the guidance became visible, so the one user it
        // existed for never saw it. Bluetooth cancels the auto-advance so the
        // row's footnote gets its moment; wired and built-in keep the
        // instant flow.
        XCTAssertTrue(MicrophoneStep.shouldAutoAdvance(current: device("usb")))
        XCTAssertTrue(MicrophoneStep.shouldAutoAdvance(current: device("mac", builtIn: true)))
        XCTAssertTrue(MicrophoneStep.shouldAutoAdvance(current: nil))
        XCTAssertFalse(MicrophoneStep.shouldAutoAdvance(current: device("airpods", bluetooth: true)))
    }

    // MARK: - transport labels

    // MARK: - first-dictation facts: local until consent

    func testOnlyTheFirstDictationIsRecorded() {
        let defaults = freshDefaults()
        FirstDictation.recordIfFirst(transport: "bluetooth", timeToAudioMs: 1850, defaults: defaults)
        FirstDictation.recordIfFirst(transport: "builtin", timeToAudioMs: 150, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: FirstDictation.transportKey), "bluetooth",
                       "the second dictation must never overwrite the first — 'first' is the whole point")
        XCTAssertEqual(defaults.integer(forKey: FirstDictation.ttaKey), 1850)
    }

    func testNothingIsEmittedWithoutConsent() {
        // The tree's measurement as originally designed was impossible under
        // opt-in telemetry; this is the resolution — and this test is the
        // policy: no consent, no transmission, ever.
        let defaults = freshDefaults()
        FirstDictation.recordIfFirst(transport: "bluetooth", timeToAudioMs: 1850, defaults: defaults)
        var sent = 0
        FirstDictation.emitIfDue(analyticsEnabled: false, defaults: defaults, send: { _, _ in sent += 1 })
        XCTAssertEqual(sent, 0)
        XCTAssertFalse(defaults.bool(forKey: FirstDictation.emittedKey),
                       "an unsent fact is still owed — a later consent must be able to emit it")
    }

    func testEmitsExactlyOnceAfterConsent() {
        let defaults = freshDefaults()
        FirstDictation.recordIfFirst(transport: "bluetooth", timeToAudioMs: 1850, defaults: defaults)
        var events: [(String, String)] = []
        FirstDictation.emitIfDue(analyticsEnabled: true, defaults: defaults, send: { events.append(($0, $1)) })
        FirstDictation.emitIfDue(analyticsEnabled: true, defaults: defaults, send: { events.append(($0, $1)) })
        XCTAssertEqual(events.count, 1, "once, ever — every launch calls this")
        XCTAssertEqual(events.first?.0, "bluetooth")
        XCTAssertEqual(events.first?.1, "1-2s")
    }

    func testNothingRecordedMeansNothingEmitted() {
        var sent = 0
        FirstDictation.emitIfDue(analyticsEnabled: true, defaults: freshDefaults(), send: { _, _ in sent += 1 })
        XCTAssertEqual(sent, 0)
    }

    func testBucketsNotMilliseconds() {
        // Buckets are the privacy mechanism — a raw latency could fingerprint.
        XCTAssertEqual(FirstDictation.ttaBucket(123), "<200ms")
        XCTAssertEqual(FirstDictation.ttaBucket(200), "200-500ms")
        XCTAssertEqual(FirstDictation.ttaBucket(499), "200-500ms")
        XCTAssertEqual(FirstDictation.ttaBucket(999), "500ms-1s")
        XCTAssertEqual(FirstDictation.ttaBucket(1850), "1-2s")
        XCTAssertEqual(FirstDictation.ttaBucket(2500), ">=2s")
    }
}
