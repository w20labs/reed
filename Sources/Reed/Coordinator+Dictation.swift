import Foundation

/// The release path: stop capture, guard the audio, and dispatch to the
/// on-device pipeline. Split from Coordinator.swift (file_length).
extension Coordinator {
    func stopAndProcess() async {
        log.info("stopAndProcess() invoked; state=\(String(describing: self.state))")
        // Invalidate any start() still awaiting its cold prewarm — see
        // pressGeneration (the prewarm race, 2026-08-24).
        pressGeneration &+= 1

        // Released while still warming up — no audio was captured. A quick tap
        // bails silently, but if the user held long enough to have actually
        // spoken, SAY that the dictation was lost (never a silent drop).
        stopKeepWarm()
        if case .warming = state {
            releasedWhileWarming()
            return
        }
        guard state == .recording else { return }
        // Captured before state/recorder teardown below — true whenever this
        // recording never confirmed real signal, regardless of mic type: a
        // disconnected USB mic or driver hiccup can lose a whole dictation
        // the same way Bluetooth's SCO handshake does. Drives the proactive
        // mic-warning toast further down; `currentMicIsBluetooth` only
        // tailors that toast's copy, not whether it shows.
        let missedRealSignal = !realSignalConfirmedForCurrentRecording
        if missedRealSignal { logWarmupAbandoned() }
        log.info("stopAndProcess: currentMicIsBluetooth=\(self.currentMicIsBluetooth) realSignalConfirmed=\(self.realSignalConfirmedForCurrentRecording) missedRealSignal=\(missedRealSignal)")
        state = .transcribing
        resetMeter()

        // Timing + facts for the content-free analytics event (see Analytics).
        let releaseAt = Date()
        // The tier the Settings Cleanup checkbox writes (three-tier review
        // 2026-08-26, F4).
        let cleanupEnabled = LocalCleanup.tier != .off

        let stopped = recorder.stopWithSegments()
        let wav = stopped.wav
        log.info("recorder.stop() returned \(wav.count) bytes")
        // 16 kHz mono int16 = 32 000 bytes/s; minus the 44-byte WAV header.
        let recMs = max(0, (wav.count - 44) * 1000 / 32_000)

        guard !droppedShortAudio(wav, missedRealSignal: missedRealSignal) else { return }

        let context = DictationContext(cleanupEnabled: cleanupEnabled, recMs: recMs, releaseAt: releaseAt)
        if overlap.isArmed {
            await processLocalOverlapped(wav: wav, context: context, stopped: stopped)
        } else {
            await processLocal(wav: wav, context: context)
        }
    }

    /// Released while still warming up — no audio was captured. A quick tap
    /// bails silently, but if the user held long enough to have actually
    /// spoken, SAY that the dictation was lost (never a silent drop).
    private func releasedWhileWarming() {
        disarmOverlap()
        warmingWatchdog?.cancel()
        warmingWatchdog = nil
        micIsPreparing = false
        // Released before the mic ever became audible — the worst case of
        // the very thing being measured, so it must be recorded.
        logWarmupAbandoned()
        _ = recorder.stop()
        resetMeter()
        let held = holdStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if held > 0.6 {
            activeError = .generic(
                headline: "Mic wasn't ready",
                detail: "The microphone was still starting up, so that dictation wasn't captured. Please try again.",
                raw: "released during warming after \(String(format: "%.1f", held))s hold")
            state = .error(activeError?.headline ?? "Mic wasn't ready")
            DebugTimings.persist(String(
                format: "DROP warming held=%.1fs bt=%@", held, String(currentMicIsBluetooth)))
        } else {
            state = .idle
        }
    }

    /// The short-audio drop, with forensics for every outcome. True when the
    /// press was dropped (state already set); false when there is audio to process.
    private func droppedShortAudio(_ wav: Data, missedRealSignal: Bool) -> Bool {
        let minBytes = Int(16_000 * 2 * 0.3)
        guard wav.count <= minBytes else { return false }
        disarmOverlap()
        log.info("audio too short (\(wav.count) bytes); skipping")
        let held = holdStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        // Forensics for every short-audio outcome — includes the recorder's
        // input/output peaks so "spoke but silence-guarded" is visible.
        DebugTimings.persist(String(
            format: "DROP short-audio wav=%d held=%.1fs signal=%@ bt=%@ | %@",
            wav.count, held, String(!missedRealSignal),
            String(currentMicIsBluetooth), recorder.lastStopStats))
        if missedRealSignal {
            state = .idle
            showMicWarning()
        } else if held > 1.0 {
            // The user held long enough to have spoken, yet the engine
            // returned almost nothing — surface it, never silently drop.
            activeError = .generic(
                headline: "No audio captured",
                detail: "The mic delivered almost no audio for that dictation. Check the input device and try again.",
                raw: "wav \(wav.count) bytes after \(String(format: "%.1f", held))s hold")
            state = .error(activeError?.headline ?? "No audio captured")
        } else {
            state = .idle
        }
        return true
    }

    /// Shared per-dictation context. Internal so the pipeline extensions can
    /// reuse it.
    struct DictationContext {
        let cleanupEnabled: Bool
        let recMs: Int
        let releaseAt: Date
    }
}

extension Coordinator {

    /// Arm a timer that flips a stuck .warming into an error so the HUD never
    /// lies about listening. Cancelled when audio arrives (onCaptureReady), the
    /// user releases during warmup, or start() throws.
    func startWarmingWatchdog() {
        warmingWatchdog?.cancel()
        warmingWatchdog = Task { @MainActor [weak self] in
            let budget = self?.currentMicIsBluetooth == true
                ? Coordinator.warmingTimeoutBluetooth : Coordinator.warmingTimeout
            try? await Task.sleep(nanoseconds: budget)
            guard let self, !Task.isCancelled else { return }
            guard case .warming = self.state else { return }
            log.error("warming watchdog fired — audio never started")
            // Invalidate any start() still suspended in its prewarm: the
            // prewarm's retry loop deliberately survives the engine rebuild
            // below, so without the bump it could arm capture into the
            // .error state this watchdog is about to set (audit 2026-08-25).
            self.pressGeneration &+= 1
            self.micIsPreparing = false
            self.abortPress()
            _ = self.recorder.stop()
            // Rebuild, don't just stop: the graph that produced zero frames
            // is poisoned (stale tap after a device switch — reed.log
            // 2026-08-05: three consecutive watchdog fires on retries that
            // reused it). stop() leaves isPrewarmed true, so every retry
            // skipped prewarm and started the same dead graph. A rebuild
            // makes the NEXT press re-prewarm from scratch.
            self.recorder.rebuildEngineForDeviceChange()
            self.resetMeter()
            let dictationError = DictationError.generic(
                headline: "Microphone didn't start",
                detail: "Reed didn't start hearing audio - a device or driver hiccup. Try again.",
                raw: "warming watchdog: no audio within 2 s")
            self.activeError = dictationError
            self.state = .error(dictationError.headline)
            self.autoClearErrorAfterDelay()
        }
    }

    /// A configuration change stopped the engine underneath an active
    /// recording — the pin race (reed.log 2026-08-05): the pin's own
    /// config-change notification landed after capture was armed, and the
    /// engine it stopped was the one recording. The capture is already dead;
    /// recover once, silently — the user is still holding the key, so a
    /// ~150 ms restart is invisible. The warming watchdog is re-armed with a
    /// fresh budget as the backstop if the retry dies too.
    func handleCaptureInterrupted() {
        switch state {
        case .warming, .recording: break
        default: return
        }
        guard !captureRetriedThisPress else {
            log.error("capture interrupted again after a retry — leaving it to the watchdog")
            return
        }
        captureRetriedThisPress = true
        log.error("capture interrupted mid-press — restarting once")
        // Same rule as start(): a restart from cold is a preparing
        // state, whatever the transport.
        micIsPreparing = currentMicIsBluetooth || !recorder.isWarm
        state = .warming
        startWarmingWatchdog()
        // Generation-checked like startRecorder: the press can end while this
        // restart is still suspended, and its stop() runs before capture is
        // armed — without the check the retry armed a zombie live mic
        // (audit 2026-08-25).
        let generation = pressGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(pressedAt: self.holdStartedAt ?? Date())
                if generation != self.pressGeneration {
                    // Same rapid re-press rule as startRecorder: a newer
                    // press's live capture must survive the stale teardown.
                    switch self.state {
                    case .warming, .recording: break
                    default:
                        log.error("press ended during capture retry — releasing the stale capture")
                        _ = self.recorder.stop()
                        self.resetMeter()
                    }
                }
            } catch {
                // The watchdog surfaces the failure on its own schedule.
                log.error("capture retry failed: \(error.localizedDescription)")
            }
        }
    }

    /// Clear the `.error` pill back to idle after 4 s — generation-checked so
    /// a stale task can't truncate a newer error posted in the meantime.
    func autoClearErrorAfterDelay() {
        errorClearGeneration &+= 1
        let generation = errorClearGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, generation == self.errorClearGeneration else { return }
            if case .error = self.state { self.state = .idle }
        }
    }

    /// Abort an in-flight dictation without transcribing — used when a chord is
    /// detected during a ⌃⌥ hold (the user was typing a shortcut, not dictating).
    func cancelDictation() {
        switch state {
        case .warming, .recording:
            // Only a live press is cancelled (review 2026-08-30, R2): once
            // the release path is running, resetting the overlap session
            // would drop every head segment and inject the tail alone.
            abortPress()
            // Same invalidation as stopAndProcess: recorder.stop() below is a
            // no-op while a cold start() is still suspended (capture not yet
            // armed), so without the bump the surviving prewarm armed a live
            // mic against an idle coordinator (audit 2026-08-25).
            pressGeneration &+= 1
            warmingWatchdog?.cancel()
            warmingWatchdog = nil
            _ = recorder.stop()
            resetMeter()
            state = .idle
        case .idle, .preparingModel, .transcribing, .injecting, .error, .notice:
            break
        }
    }
}
