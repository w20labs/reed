import AVFoundation
import Foundation
import ReedObjC

/// Who may touch the engine right now. `start()` and `prewarm()` run off the
/// main thread (nonisolated async), while the main thread replaces the engine
/// (the warming watchdog, config-change notifications, a mic-setting change).
/// Unsynchronized, a replacement landing between prewarm's return and
/// `engine.start()` started a fresh, empty engine: an uncatchable NSException
/// ("inputNode != nullptr || outputNode != nullptr"), crash report
/// 2026-10-11-231422, AirPods connecting during a press.
///
/// Background segments `hold` the gate and block for it. The main thread
/// never blocks — an engine call can take seconds during a device switch —
/// so a mutation it asks for while a segment holds the gate is queued and run
/// by that segment's thread as it lets go, still holding the gate.
final class EngineGate {
    private let lock = NSRecursiveLock()
    /// Guards `deferred` and `ownerActive`; never held across an engine call.
    private let queueLock = NSLock()
    private var deferred: [() -> Void] = []
    /// A background segment owns `lock`: main must queue, not wait.
    private var ownerActive = false
    /// Nesting on the owning thread; touched only while holding `lock`.
    private var depth = 0

    /// Run a background segment with the engine to itself. Blocks for the gate.
    func hold<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        enter(owner: true)
        defer { leave() }
        return try body()
    }

    /// Replace or stop the engine. Off main this is `hold`; on main it runs
    /// now when the gate is free, otherwise it is queued for the holder.
    /// `body` must decide at run time, not at the call: a queued mutation
    /// runs after the segment that delayed it.
    func mutate(_ body: @escaping () -> Void) {
        guard Thread.isMainThread else { return hold(body) }
        while true {
            if lock.try() {
                enter(owner: false)
                defer { leave() }
                return body()
            }
            queueLock.lock()
            if ownerActive {
                deferred.append(body)
                queueLock.unlock()
                return
            }
            queueLock.unlock()
            // The holder is between letting go of the queue and the lock.
        }
    }

    private func enter(owner: Bool) {
        depth += 1
        guard depth == 1, owner else { return }
        queueLock.lock()
        ownerActive = true
        queueLock.unlock()
    }

    private func leave() {
        defer { lock.unlock() }
        guard depth == 1 else { depth -= 1; return }
        while true {
            queueLock.lock()
            guard !deferred.isEmpty else {
                ownerActive = false
                queueLock.unlock()
                break
            }
            let next = deferred.removeFirst()
            queueLock.unlock()
            next()
        }
        depth -= 1
    }
}

extension AudioRecorder {
    enum RecorderError: LocalizedError {
        case micDenied
        case converterFailed
        case noInput
        case deviceFormatMismatch
        /// The engine prewarm readied was replaced before it could start.
        case engineReplaced
        /// `engine.start()` raised an NSException instead of throwing.
        case engineStartRaised

        var errorDescription: String? {
            switch self {
            case .deviceFormatMismatch:
                return "The selected microphone couldn't be started at its own format"
            case .micDenied: return "Microphone permission denied"
            case .converterFailed: return "Failed to create audio converter"
            case .noInput: return "No audio input device available"
            case .engineReplaced: return "The audio engine was replaced while starting"
            case .engineStartRaised: return "The audio engine raised an exception while starting"
            }
        }
    }

    /// The tail of `start()`, run holding the engine gate: reset the
    /// per-recording state, start (or resume) the engine prewarm readied, and
    /// arm capture. Nothing can replace the engine from here to the end.
    func armCapture() throws {
        // The engine prewarm returned may already be gone: a main-thread
        // replacement (watchdog, config change) could land before the gate
        // was taken, and starting the fresh, never-prepared engine is the
        // 2026-10-11 SIGABRT. A thrown error is the caller's to surface.
        guard isPrewarmed else {
            alog.error("engine replaced between prewarm and start — not starting it")
            throw RecorderError.engineReplaced
        }
        // All flag mutations go through bufferQueue so they're serialized
        // with the tap callback (which also touches them on bufferQueue).
        // Without this, capturedAnyFrame can appear stale to the tap and
        // onCaptureReady silently never fires for this recording.
        bufferQueue.sync {
            pcmBuffer = Data()
            inputPeak = 0
            droppedOverflow = false
            capturedAnyFrame = false
            consecutiveLoudBuffers = 0
            reportedRealSignal = false
            recordingArmedAt = Date()
            // Fresh meter calibration per recording — the last session's
            // speech reference and noise floor must not carry into a new
            // environment.
            meterReferenceDB = Self.meterNoiseFloorMinDB
            meterNoiseFloorDB = 0.0
            segmenter = SpeechSegmenter()
        }
        // A held-warm stream is already running and muted: unmuting is the
        // whole of the work, and skips the ~1700 ms profile switch.
        resumedFromWarmHold = resumeFromWarmHold()
        if !resumedFromWarmHold {
            // Defensive unmute (race finding, 2026-08-25): this start()
            // can JOIN beginWarmHold's in-flight MUTED prewarm before its
            // hold is armed — capture would then record HAL silence for
            // the whole dictation. No-op when not muted.
            _ = ProcessAudio.setInputMuted(false)
            if !engine.isRunning {
                // (Pin freshness is handled in start() by forcing the
                // prewarm rebuild; see the comment on the invalidate.)
                try startEngineCatchingExceptions()
            }
        }
        capturingFromBluetooth = boundInputDeviceID.map(AudioInputDevice.isBluetooth) ?? true
        warmEngineStartedAt = Date()
        // Debug hook: with REED_DEBUG_NO_CAPTURE=1 we start the engine but
        // never arm capture, so the tap discards every frame and
        // onCaptureReady never fires — exactly the "audio never started"
        // failure the Coordinator's warming watchdog exists to catch. Lets
        // us deterministically exercise that path without a real device
        // glitch. Off by default.
        let suppressCapture = ProcessInfo.processInfo.environment["REED_DEBUG_NO_CAPTURE"] == "1"
        bufferQueue.sync { isCapturing = !suppressCapture }
        if suppressCapture {
            alog.error("REED_DEBUG_NO_CAPTURE=1 — capture suppressed (warming-watchdog test)")
        } else {
            alog.info("capture armed from \(self.boundInputDescription) "
                + "(isCapturing=true, capturedAnyFrame=false)")
        }
    }

    /// `engine.start()` that can't abort the process. With the gate the
    /// engine is never swapped mid-segment; this is the backstop for a race
    /// invisible from outside, the same role the catcher plays at installTap.
    func startEngineCatchingExceptions() throws {
        var thrown: Error?
        let exception = ObjCExceptionCatcher.catchException { [engine] in
            do { try engine.start() } catch { thrown = error }
        }
        if let exception {
            alog.error("engine.start raised \(exception.name.rawValue): \(exception.reason ?? "<no reason>")")
            throw RecorderError.engineStartRaised
        }
        if let thrown { throw thrown }
    }
}

private let alog = Log(category: "audio")
