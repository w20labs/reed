import AVFoundation
import Foundation

/// The config-change decision table, split out of AudioRecorder.swift for the
/// swiftlint file-length cap (same pattern as AudioRecorder+Capture.swift).
extension AudioRecorder {
    /// What the config-change handler should do — pure, so the decision
    /// table is testable without CoreAudio.
    enum ConfigChangeAction: Equatable { case absorb, interruptCapture, invalidate }

    static func configChangeAction(capturing: Bool, tapLive: Bool,
                                   msSincePin: Double?) -> ConfigChangeAction {
        // A stopped engine under an active capture is fatal no matter who
        // caused it — our own pin included.
        if capturing { return .interruptCapture }
        // A change reconfigures the graph; an installed tap belongs to the
        // OLD graph and will never fire again. Absorbing with a live tap is
        // how the pin race survived the first fix (reed.log 18:46:35) —
        // absorb is only safe while there is nothing to invalidate.
        if tapLive { return .invalidate }
        if let ms = msSincePin, ms < selfInflictedGraceMs { return .absorb }
        return .invalidate
    }

    /// Tears down the audio chain after a device switch. Stops the engine,
    /// removes its tap, and replaces the AVAudioEngine instance with a
    /// brand new one — calling `installTap` on a stale node after a
    /// configuration change throws an uncatchable NSException, so
    /// re-using the old engine across a device switch is not safe.
    /// Rebuild so the input node is instantiated against the current device.
    func rebuildEngineForDeviceChange() { invalidate() }
    func invalidate() {
        // Block-based observers are removed by token; removeObserver(self)
        // silently did nothing here and leaked one registration per rebuild.
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        if engine.isRunning { engine.stop() }
        // Two guards on touching inputNode:
        // - hasAudioInput: same NSException risk as prewarm — never touch it
        //   when the device is gone (invalidate often fires *because* one was
        //   removed).
        // - isPrewarmed: merely ACCESSING engine.inputNode on a never-prewarmed
        //   engine INSTANTIATES the input unit, bound to the system-default
        //   device — on AirPods that opens the device and triggers the 2-3s
        //   A2DP→HFP audio drop (hand-test finding: picking a wired mic in
        //   onboarding dropped AirPods playback). The tap only ever exists
        //   after prewarm, so with isPrewarmed false there is nothing to
        //   remove and no reason to summon the node.
        if isPrewarmed, Self.hasAudioInput() {
            engine.inputNode.removeTap(onBus: 0)
        }

        engine = AVAudioEngine()
        observeConfigChange()

        // A hold belongs to the device it was taken on; the engine being
        // replaced means that device is gone or changed underneath us.
        keepWarmReleaseTask?.cancel()
        keepWarmReleaseTask = nil
        ProcessAudio.setInputMuted(false)

        // Tap-visible state resets under bufferQueue: the tap thread reads
        // isCapturing and the converter concurrently (race finding,
        // 2026-08-25). A late in-flight callback holding the old converter
        // reference finishes safely; it can never observe a torn reset.
        bufferQueue.sync {
            converter = nil
            converterSourceFormat = nil
            isCapturing = false
            pcmBuffer = Data()
        }
        isPrewarmed = false
        tapInstalled = false
        selfInflictedPinAt = nil
    }
}
