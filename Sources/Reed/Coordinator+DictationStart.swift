import AppKit
import Foundation

/// The dictation-start path, split from Coordinator.swift (file_length): the
/// hotkey press — guards, per-press reset, recorder callbacks, and the
/// generation-checked awaited engine start.
extension Coordinator {
    func start() async {
        // Busy FIRST (review 2026-09-06): a second hotkey while a press is
        // live must touch nothing — the refusal below used to be able to
        // flip a recording press to .error. Errors don't block — they get
        // retried.
        switch state {
        case .warming, .recording, .preparingModel, .transcribing, .injecting: return
        case .idle, .error, .notice: break
        }
        // Setup incomplete: the hotkey summons onboarding, never the pipeline
        // (P12 follow-up, 2026-08-07 — field report: the hotkey worked before
        // onboarding finished, surfacing a raw mic-permission error). The
        // gate is on PRECONDITIONS, not ceremony: once the speech model is
        // installed, dictation is legitimate even mid-flow — the Done step
        // invites exactly that test dictation before "Get started" stamps
        // completion (second field report, same day). Reed has no terms to
        // accept (2026-09-26), so the model is the whole precondition.
        if Self.setupBlocksDictation(onboardingPending: OnboardingState.shouldShowOnFirstLaunch(),
                                     modelInstalled: ModelStore.isSpeechModelInstalled) {
            openOnboarding()
            return
        }
        // The speech model's state, refused HERE too (review 2026-09-03, P1):
        // a download in flight, a failed one, or files that went missing
        // used to be discovered on the release path — after the user had
        // spoken — and that dictation was thrown away. Nothing is captured;
        // the pill and the menu banner say what is happening and offer
        // Try again where there is one.
        if let refusal = speechModelRefusal() {
            activeError = refusal
            state = .error(refusal.headline)
            return
        }
        log.info("start() invoked; state=\(String(describing: self.state))")
        // Starting a fresh dictation optimistically clears the last failure —
        // the menubar dot + menu banner drop the moment the user retries.
        activeError = nil
        // Any error this press produces is NEW — a pending 4 s auto-clear
        // from a previous error must not truncate its pill.
        errorClearGeneration &+= 1
        // Fresh per-dictation network tally (the acceptance test asserts zero).
        NetworkGate.shared.activity.reset()
        lastTimings = nil
        holdStartedAt = Date()
        // The local-review collector (P16) observes this press's cleanup.
        beginReview()
        // Overlapped cleanup (step 2): seal + process segments during the press.
        armOverlapIfEnabled()
        let generation = pressGeneration
        // Warm the on-device cleanup model while the user is still speaking —
        // kills the random 1.4 s first-AI-call penalty after idle — and keep
        // it hot for the whole hold (lever 6: it cools again within ~5 s).
        if #available(macOS 26.0, *) {
            AICleanup.prewarm()
        }
        startKeepWarm()
        realSignalConfirmedForCurrentRecording = false
        // Fire the "ready" cue the moment audio actually starts flowing,
        // not when engine.start() returns (those moments are ~100–500 ms apart).
        // Plays instantly, always — even on a Bluetooth mic, where the SCO
        // handshake may still be silent at this exact instant. Trading cue
        // accuracy for responsiveness here is intentional: if it turns out
        // the mic genuinely wasn't ready in time, `micWarning` (driven by
        // onRealSignalConfirmed below) tells the user proactively on
        // release, rather than delaying the cue on every single recording
        // to guard against it.
        recorder.onCaptureReady = { [weak self] in
            guard let self else { return }
            log.info("onCaptureReady fired; state=\(String(describing: self.state))")
            // If the user already released, we're back to idle — drop the cue.
            guard case .warming = self.state else {
                log.info("onCaptureReady ignored (state no longer warming)")
                return
            }
            // On Bluetooth the first frame proves the tap is installed, NOT
            // that the mic can hear: during the A2DP->SCO switch the device
            // delivers digital silence for another ~0.5-1.5 s. Going live here
            // makes the cue a lie — the user starts talking and the opening
            // words never existed. Wait for onRealSignalConfirmed instead,
            // which fires on room tone (captureReadyPeakFloor is below quiet
            // room tone, not speech-level), so it means "the link is streaming"
            // rather than "the user spoke". Wired mics have real signal from
            // frame one and are unchanged — delaying them to guard against a
            // problem they don't have would be a regression.
            guard !self.currentMicIsBluetooth else {
                log.info("bluetooth mic — deferring the ready cue to real signal")
                return
            }
            // Second net for the prewarm race: a frame that arrives after the
            // press ended must not resurrect the HUD into "Listening".
            guard case .warming = self.state else { return }
            self.warmingWatchdog?.cancel()
            self.warmingWatchdog = nil
            self.micIsPreparing = false
            self.state = .recording
            log.info("state -> recording")
            self.playPopSound()
        }
        // Tracks whether real signal ever showed up during this recording —
        // stopAndProcess checks this on release to decide whether to warn.
        recorder.onRealSignalConfirmed = { [weak self] in
            guard let self else { return }
            log.info("onRealSignalConfirmed fired; state=\(String(describing: self.state))")
            self.realSignalConfirmedForCurrentRecording = true
            // Measured before the state guard below: a press whose signal
            // lands just after release is exactly the case being chased, and
            // dropping it would flatter the numbers.
            self.logWarmupSucceeded()
            // Bluetooth's honest "you can speak now": the SCO link is streaming
            // audible frames. Wired mics already went live on first frame, so
            // this is a no-op for them (state is no longer .warming).
            guard case .warming = self.state else { return }
            self.warmingWatchdog?.cancel()
            self.warmingWatchdog = nil
            self.micIsPreparing = false
            self.state = .recording
            log.info("state -> recording (bluetooth, on real signal)")
            self.playPopSound()
        }
        // Bluetooth holds the stream for the SCO link (design: holding the
        // link warm). A PINNED input holds it for a different reason
        // (2026-08-07): a pin does not survive an engine stop→start cycle —
        // honoring it cold requires a full prewarm rebuild, which audibly
        // dips any playing audio while the aggregate engages. Holding the
        // pinned engine warm makes every following press a resume: pin
        // intact, no rebuild, no dip, and the ready cue fires immediately.
        recorder.shouldHoldWarm = currentMicIsBluetooth || AudioInputDevice.hasPreferredPin
        recorder.onCaptureInterrupted = { [weak self] in self?.handleCaptureInterrupted() }
        captureRetriedThisPress = false
        // "Preparing mic…" = not live YET, any transport: cold starts measure
        // ~750/860 ms (engine/first frame) vs 31/67 warm — without this the
        // HUD claimed Listening at a flat waveform and users spoke into a
        // deaf mic. A warm resume stays silent, so nothing flickers.
        micIsPreparing = currentMicIsBluetooth || !recorder.isWarm
        state = .warming
        startWarmingWatchdog()
        await startRecorder(generation: generation)
    }

    /// The awaited leg of `start()`, generation-checked: the press can END
    /// during a cold prewarm (the 2026-08-24 race) — the warming branch's
    /// recorder.stop() runs before capture is armed and tears nothing down,
    /// so without the check the mic stays live (indicator on) with the
    /// coordinator idle, and the next release pastes ambient room audio.
    private func startRecorder(generation: Int) async {
        do {
            try await recorder.start(pressedAt: self.holdStartedAt ?? Date())
            if generation != pressGeneration {
                // Rapid re-press (review 2026-08-25): a NEWER press may
                // already own the capture on the shared engine — stopping
                // here would kill its live recording. Tear down only when no
                // dictation is active anymore.
                switch state {
                case .warming, .recording: break
                default:
                    log.error("press ended during mic start — releasing the stale capture")
                    _ = recorder.stop()
                    resetMeter()
                }
            }
        } catch {
            // A stale press's failure has nothing to surface.
            guard generation == pressGeneration else { return }
            warmingWatchdog?.cancel()
            warmingWatchdog = nil
            log.error("recorder.start failed: \(error.localizedDescription)")
            abortPress()
            resetMeter()
            let dictationError = DictationError.classify(error)
            activeError = dictationError
            state = .error(dictationError.headline)
        }
    }

    /// Whether an unfinished setup must take the hotkey instead of dictation:
    /// only while onboarding is pending AND the speech model is missing.
    nonisolated static func setupBlocksDictation(onboardingPending: Bool, modelInstalled: Bool) -> Bool {
        onboardingPending && !modelInstalled
    }
}
