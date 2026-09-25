import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

private let alog = Log(category: "audio")

final class AudioRecorder {
    // Tuned thresholds (silence floor, capture-ready gates, recording cap)
    // live in AudioRecorder+Tuning.swift with their field stories.

    // Internal: the capture extension restarts/rebuilds it on -10868.
    var engine = AVAudioEngine()
    // Internal: prewarm() lives in the +Capture extension (file_length).
    var isPrewarmed = false
    var converter: AVAudioConverter?
    /// The format `converter` was built for. Each tap buffer carries the live
    /// format, which can differ from what the node reported at prewarm time
    /// (pinning a Bluetooth device changes it asynchronously) — so the
    /// converter is rebuilt whenever it drifts. See `converter(for:)`.
    var converterSourceFormat: AVAudioFormat?
    // When we last pinned the input device ourselves — the pin fires the same
    // AVAudioEngineConfigurationChange as a genuine device switch, and this
    // stamp is how the handler tells them apart (decision table + full field
    // story: AudioRecorder+ConfigChange.swift). A timestamp, not a one-shot
    // boolean: a pin that changes nothing emits NO notification, and the old
    // boolean then leaked into swallowing the next genuine change. Internal:
    // set by pinPreferredInputIfSet() in the +Capture extension.
    var selfInflictedPinAt: Date?
    /// Absorbable-echo window after a pin (idle only). Delivery is
    /// next-runloop; observed 133 ms — 1 s is generous without going stale.
    static let selfInflictedGraceMs: Double = 1_000
    /// Prewarm's post-pin settle before installing the tap, so the pin's
    /// echo lands while there is nothing to invalidate (see +ConfigChange).
    static let pinEchoSettleNs: UInt64 = 350_000_000
    /// Whether a tap is currently installed — an echo stops being absorbable
    /// the moment this is true (see configChangeAction).
    var tapInstalled = false
    /// The one in-flight prewarm; later callers must JOIN it, not run a
    /// second body (why: prewarm() in the +Capture extension).
    var prewarmTask: Task<Void, Error>?
    /// Token for the block-based config-change observer. Block observers are
    /// removed by TOKEN — removeObserver(self) does not touch them, so every
    /// engine rebuild leaked a stale registration (finding 2026-08-25).
    var configChangeObserver: NSObjectProtocol?

    /// Fired (on main) when a configuration change stops the engine while a
    /// recording is capturing — the recording is already dead at that point.
    /// The Coordinator uses this to restart the capture mid-press instead of
    /// letting the warming watchdog time out 2 s later.
    var onCaptureInterrupted: (() -> Void)?

    // Internal (not private): shared with the AudioRecorder+Capture extension,
    // which implements the tap callback's buffer conversion + buffering.
    let bufferQueue = DispatchQueue(label: "reed.audio.buffer")
    var pcmBuffer = Data()
    var isCapturing = false     // gates whether tap data is saved
    var inputPeak: Float = 0    // tracks raw mic peak before conversion
    /// Numeric stats of the last stopped recording — the silence-artifact
    /// filter needs the RMS as a number, not the formatted lastStopStats line.
    private(set) var lastRecordingPeakDB: Double = -120
    private(set) var lastRecordingRMSdB: Double = -120
    var droppedOverflow = false
    var consecutiveLoudBuffers = 0    // tracks sustained signal for onRealSignalConfirmed
    var recordingArmedAt: Date?
    var reportedRealSignal = false
    var capturedAnyFrame = false
    /// Live segmentation (latency step 2): while on, pause-delimited slices
    /// of the recording are sealed as they complete so the pipeline can
    /// transcribe + clean them WHILE the user keeps talking. All of this
    /// lives on bufferQueue (review 2026-08-30, R3/R8): sealed segments wait
    /// in `pendingSealed` until the main actor takes them — on the
    /// notification, or atomically inside stop() — so a seal landing as the
    /// user releases is neither dropped nor leaked into the next press.
    var segmentingEnabled = false
    var segmenter = SpeechSegmenter()
    var pendingSealed: [SealedSegment] = []
    /// A notification only — the segments come from `takeSealedSegments()`.
    var onSegmentSealed: (() -> Void)?

    /// Compact stats from the last `stop()` (input/output peaks, sample count,
    /// silence verdict) — persisted by the drop-forensics lines, since logd on
    /// some machines retains nothing from the app.
    private(set) var lastStopStats = ""

    /// Called on the main thread the moment the tap delivers its first buffer
    /// for the current recording. Fires unconditionally (not gated on real
    /// signal) so the "ready" cue feels immediate — Bluetooth mics may still
    /// be silent for another ~1-1.5s at this point; see `onRealSignalConfirmed`.
    var onCaptureReady: (() -> Void)?

    /// Called on the main thread the first time real signal (sustained,
    /// above the noise floor) is confirmed for the current recording — fast
    /// or slow, Bluetooth or not. The Coordinator uses this to track whether
    /// a recording ever actually heard anything: if the user releases the
    /// hotkey on a Bluetooth mic before this has fired, the SCO handshake
    /// most likely ate the whole dictation, and it surfaces a warning.
    var onRealSignalConfirmed: (() -> Void)?

    /// Called on the main thread ~12×/s with the current mic level (0…1) while
    /// recording, for the HUD's live meter. nil when nobody is listening.
    var onLevel: ((Float) -> Void)?

    // MARK: - Warm-up instrumentation
    //
    // The wait between pressing the hotkey and the mic actually hearing, split
    // into its parts so the cost can be attributed rather than guessed at:
    // engine start, first tap callback, and first sustained audible frame.
    // Only the last one is the number the user feels. Timestamps are recorded
    // here and emitted by the Coordinator, which knows the device type —
    // enumerating CoreAudio devices on the audio thread would perturb the very
    // measurement being taken.

    /// When the hotkey went down, as opposed to when the recorder was reached.
    private(set) var warmPressedAt: Date?
    /// When `engine.start()` returned (a Bluetooth link may still be silent).
    private(set) var warmEngineStartedAt: Date?
    /// First tap callback of this recording: proves the tap is installed, not
    /// that the device can hear. Internal, not `private(set)`: written from
    /// the +Warmup extension, which lives in another file (file_length).
    var warmFirstFrameAt: Date?
    /// Whether the engine was already running — did this press pay cold start.
    private(set) var warmEngineWasRunning = false
    /// Sample rate the tap actually delivered, which reveals the negotiated
    /// Bluetooth profile (8/16 kHz telephony vs 24/48 kHz wideband).
    var warmSampleRate: Double = 0
    /// Pending release of a held-warm stream; non-nil exactly while holding.
    var keepWarmReleaseTask: Task<Void, Never>?
    /// Served from a held-warm stream — see `requiredLoudBuffers`.
    var resumedFromWarmHold = false
    /// Bound input is Bluetooth — resolved once at `start()`, never in the tap
    /// callback. Defaults true: unresolved keeps the connect-click filter.
    var capturingFromBluetooth = true
    /// Whether the live input is one that benefits from being held open.
    /// Set by the Coordinator, which already resolves the device — enumerating
    /// CoreAudio inside `stop()` would put that work on the release path.
    var shouldHoldWarm = false

    init() {
        observeConfigChange()
        // Deferred: unlike the NotificationCenter add above, this is a coreaudiod round-trip that blew Coordinator's init budget inline.
        DispatchQueue.main.async { [weak self] in self?.observeDefaultDeviceChanges() }
    }

    /// Subscribe to AVAudioEngineConfigurationChange for the *current* engine
    /// instance. Must be re-called after `invalidate()` replaces the engine.
    /// Marshalled onto main so it can't race with hotkey-triggered prewarm.
    func observeConfigChange() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let capturing = self.bufferQueue.sync { self.isCapturing }
            let msSincePin = self.selfInflictedPinAt.map { Date().timeIntervalSince($0) * 1_000 }
            // The stamp AGES OUT rather than being consumed: a device switch
            // can emit two notifications, and consuming the stamp on the
            // first sent the second into `invalidate` — which replaced the
            // engine mid-settle and crashed prewarm's installTap on the old
            // node (crash report 2026-08-05-1151, SIGABRT in InstallTapOnNode).
            switch Self.configChangeAction(
                capturing: capturing, tapLive: self.tapInstalled, msSincePin: msSincePin) {
            case .absorb:
                alog.info("AVAudioEngine config change from our own device pin (\(Int(msSincePin ?? 0))ms ago, idle) — absorbing")
            case .interruptCapture:
                alog.error("AVAudioEngine config change stopped the engine mid-capture — invalidating and signaling recovery")
                self.invalidate()
                if let cb = self.onCaptureInterrupted { DispatchQueue.main.async(execute: cb) }
            case .invalidate:
                alog.info("AVAudioEngine config change — invalidating prewarm")
                self.invalidate()
            }
        }
    }

    /// Call after the user changes their preferred-microphone setting so the
    /// next recording re-pins immediately, instead of waiting for an
    /// unrelated device notification to force a rebuild. Safe to call anytime.
    func applyPreferredInputChange() {
        alog.info("applyPreferredInputChange — invalidating prewarm to re-pin next recording")
        invalidate()
    }

    // Internal (not private): read by the AudioRecorder+Capture extension.
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// True when the machine has at least one audio input device. Guards every
    /// access to `engine.inputNode`, which crashes the process with an
    /// uncatchable NSException when there is none (Sentry APPLE-IOS-K).
    /// `AVCaptureDevice.default(for:)` enumerates without needing permission and
    /// returns nil when no input hardware is present.
    ///
    /// Internal, not private: `prewarm()` lives in the +Capture extension
    /// (file_length) and guards on this.
    static func hasAudioInput() -> Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }

    /// Rolling per-session speech reference (dBFS) the HUD meter's bars are
    /// drawn against — fast attack, slow decay, floored just above the noise
    /// floor. Reset per recording in `start()`; mutated on `bufferQueue` by the
    /// AudioRecorder+Meter extension's `emitLevel` (internal, not private,
    /// because extensions in other files can't see `private` members).
    var meterReferenceDB = AudioRecorder.meterNoiseFloorMinDB
    /// Rolling per-session noise floor (dBFS): the input chain's room tone,
    /// whatever its gain. Drops instantly to any quieter buffer; only
    /// near-floor buffers pull it up (slowly), so speech can't drag it into
    /// its own range. Starts at 0 = "first buffer takes it".
    var meterNoiseFloorDB = 0.0

    /// - Parameter pressedAt: when the hotkey actually went down, so the
    ///   measured warm-up covers what the user waits through rather than
    ///   starting from wherever the Coordinator got to.
    func start(pressedAt: Date = Date()) async throws {
        do {
            warmPressedAt = pressedAt
            warmEngineStartedAt = nil
            warmFirstFrameAt = nil
            warmSampleRate = 0
            warmEngineWasRunning = engine.isRunning
            // A pinned input does not survive a stop→start cycle on a stale
            // engine: re-asserting CurrentDevice just before engine.start()
            // returns noErr yet the capture still comes from the default
            // aggregate (field log 2026-08-07 22:21:26 — pin logged, frames
            // arrived at the aggregate's rate). Every capture that honored
            // the pin went through the full prewarm: pin after prepare, echo
            // settle, tap at the pinned device's rate. So when a pin exists
            // and the engine is cold, rebuild through that path instead of
            // trusting the stale prewarm.
            if AudioInputDevice.hasPreferredPin, !engine.isRunning {
                invalidate()
            }
            // A running (warm-held) engine can silently drift off the pin
            // without ever stopping — see `isPinnedInputDrifted`. Same
            // remedy as the stale-prewarm case above: invalidate so the
            // prewarm below re-pins from scratch, instead of resuming onto
            // the wrong device.
            if AudioInputDevice.hasPreferredPin, engine.isRunning, isPinnedInputDrifted {
                alog.error("warm hold drifted off the pinned mic (bound to \(self.boundInputDescription)) — rebuilding")
                invalidate()
            }
            if !isPrewarmed {
                try await prewarm()
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
                    // (Pin freshness is handled above by forcing the prewarm
                    // rebuild; see the comment on the invalidate.)
                    try engine.start()
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
        } catch {
            alog.error("start failed: \(error.localizedDescription) — invalidating")
            invalidate()
            throw error
        }
    }

    func stop() -> Data { stopWithSegments().wav }

    func stopWithSegments() -> StopResult {
        let wasCapturing: Bool = bufferQueue.sync {
            let was = isCapturing
            isCapturing = false
            return was
        }
        guard wasCapturing else { return StopResult(wav: Data(), sealedOffset: 0, pending: []) }
        // Was: unconditional engine.stop(). Now the stream is held open and
        // HAL-muted on Bluetooth, which turns the indicator off just as
        // reliably while keeping the link in its call profile — see
        // AudioRecorder+KeepWarm. Anything else stops exactly as before.
        holdWarmOrStop(shouldHold: shouldHoldWarm)

        return bufferQueue.sync {
            let pcm = pcmBuffer
            pcmBuffer = Data()
            // No seal may land after this point, and none is lost: whatever
            // sealed but was not taken travels out with the recording.
            segmentingEnabled = false
            onSegmentSealed = nil
            let sealedOffset = segmenter.segmentStartByte
            let pending = pendingSealed
            pendingSealed = []

            // Peak + RMS of the captured samples: did the mic actually hear
            // anything? (See RecordingLevels.)
            let levels = RecordingLevels.measure(pcm: pcm)
            let sampleCount = levels.sampleCount
            let peakDB = levels.peakDB
            let inputPeakDB = inputPeak > 0 ? 20 * log10(Double(inputPeak)) : RecordingLevels.floorDB
            lastRecordingPeakDB = peakDB
            lastRecordingRMSdB = levels.rmsDB
            lastStopStats = String(
                format: "in %.1fdB out n=%d peak %.1fdB rms %.1fdB floor %.0fdB%@",
                inputPeakDB, sampleCount, peakDB, levels.rmsDB, Self.silenceFloorDB,
                peakDB < Self.silenceFloorDB ? " SILENT" : "")
            alog.info("levels: \(self.lastStopStats)")

            // "Said nothing" guard: if even the loudest captured sample is quiet,
            // the recording is silence — return empty audio. The recorder does
            // not decide what happens next: the pipeline reads the empty result
            // and skips recognition, showing "Nothing to write" instead of
            // letting a recognizer hallucinate a phrase out of silence.
            // Any real utterance, even a quiet one, peaks well above this.
            if peakDB < Self.silenceFloorDB {
                alog.info("recording silent (peak \(String(format: "%.1f", peakDB)) dBFS < \(Self.silenceFloorDB)) — skipping transcription")
                return StopResult(wav: Data(), sealedOffset: sealedOffset, pending: pending)
            }

            let wav = WAVWriter.wrap(
                pcm: pcm,
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 16
            )

            // Opt-in debug dump for offline inspection — off by default to
            // avoid writing the user's voice to /tmp on every recording.
            // This is the RAW capture: processLocal denoises a
            // copy of this WAV before ASR (see Denoiser), so /tmp/reed_last.wav
            // will differ from what Whisper actually sees on that path.
            if ProcessInfo.processInfo.environment["REED_DEBUG_AUDIO"] == "1" {
                let tmp = URL(fileURLWithPath: "/tmp/reed_last.wav")
                try? wav.write(to: tmp)
                alog.info("wrote /tmp/reed_last.wav (\(wav.count) bytes)")
            }

            return StopResult(wav: wav, sealedOffset: sealedOffset, pending: pending)
        }
    }
}
