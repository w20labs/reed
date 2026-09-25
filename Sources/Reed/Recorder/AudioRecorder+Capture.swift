import AVFoundation
import Foundation
import ReedObjC

private let alog = Log(category: "audio")

/// Tap-buffer conversion and buffering: split out of `prewarm()`'s tap
/// closure to keep AudioRecorder.swift under the swiftlint file-length and
/// function-complexity caps (see Coordinator+ModeHotkeys.swift for the same
/// pattern applied to Coordinator.swift).
extension AudioRecorder {
    // A Bluetooth device coming out of A2DP exposes no input stream until
    // macOS switches it to HFP, which runs 0.5-1.5 s.
    static var inputReadyTimeoutMs: Int { 2_500 }
    static var inputReadyPollMs: Int { 125 }

    /// The input node's format once it is usable — waiting if it isn't yet.
    ///
    /// Two things this deliberately does NOT do. It does not give up on the
    /// first look: a Bluetooth device pinned while still in A2DP reports zero
    /// input channels, and failing there turns "AirPods selected" into a
    /// permanent "No microphone found". And it does not compare against the
    /// device's nominal sample rate — that query returns a rate the device is
    /// *capable* of (24000 in HFP) rather than the one it is running, so
    /// comparing rejected healthy devices running fine at 48000. Usability is
    /// all that's worth asserting; engine.start() is the authority on the rest.
    func usableInputFormat(_ input: AVAudioInputNode) async throws -> AVAudioFormat {
        // The format returned is the reading that passed — never a fresh,
        // unvalidated read that the A2DP transient could turn back to zero
        // channels (review 2026-09-01).
        let (format, waited) = try await Self.waitForUsableFormat(
            read: { input.outputFormat(forBus: 0) },
            rateAndChannels: { ($0.sampleRate, Int($0.channelCount)) })
        DebugTimings.persist(String(
            format: "MIC prewarm ok after %dms rate=%.0f ch=%d",
            waited, format.sampleRate, format.channelCount))
        return format
    }

    /// The poll-until-ready core of `usableInputFormat`, separated from
    /// AVAudioEngine so the not-ready → retry → `noInput` behavior is
    /// testable (the A2DP zero-channel state cannot be fabricated with a
    /// real input node). Returns the reading that passed and how long it waited.
    static func waitForUsableFormat<Reading>(
        pollMs: Int = inputReadyPollMs, timeoutMs: Int = inputReadyTimeoutMs,
        read: () -> Reading, rateAndChannels: (Reading) -> (Double, Int)
    ) async throws -> (reading: Reading, waitedMs: Int) {
        var reading = read()
        var (rate, channels) = rateAndChannels(reading)
        var waitedMs = 0
        while rate <= 0 || channels == 0 {
            guard waitedMs < timeoutMs else {
                DebugTimings.persist(String(
                    format: "MIC not-ready after %dms rate=%.0f ch=%d", waitedMs, rate, channels))
                throw RecorderError.noInput
            }
            try? await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
            waitedMs += pollMs
            reading = read()
            (rate, channels) = rateAndChannels(reading)
        }
        return (reading, waitedMs)
    }

    /// Start the engine, recovering once from `kAudioUnitErr_FormatNotSupported`.
    ///
    /// -10868 means the unit was pinned to a device that isn't offering the
    /// format the node cached. Rebuilding instantiates the input node against
    /// whatever the device is doing NOW, which is the only reliable way to
    /// resynchronise them — and it happens after a real failure rather than on
    /// a guess about one.
    func startEngineRecoveringFormatMismatch() throws {
        do {
            try engine.start()
        } catch let error as NSError where error.code == -10868 {
            DebugTimings.persist("MIC start -10868 — rebuilding and retrying once")
            rebuildEngineForDeviceChange()
            // The device vanishing is one of the very conditions that produce
            // -10868 — and touching the rebuilt engine's inputNode with no
            // input device present raises the uncatchable "inputNode !=
            // nullptr" NSException (Sentry APPLE-IOS-K), a hard SIGABRT.
            // Same guard as prewarmBody/invalidate; pinPreferredInputIfSet
            // below also reaches inputNode, so check before either
            // (review 2026-08-26).
            guard Self.hasAudioInput() else {
                DebugTimings.persist("MIC recovery aborted — no input device after rebuild")
                throw RecorderError.noInput
            }
            engine.prepare()
            let pinnedDeviceID = pinPreferredInputIfSet()
            engine.prepare()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // Pinned taps need the device's own rate, not the node's
            // aggregate-derived one — same reasoning as prewarmBody.
            let tapFormat: AVAudioFormat? = pinnedDeviceID.flatMap { id in
                AudioInputDevice.nominalSampleRate(id).flatMap {
                    AVAudioFormat(standardFormatWithSampleRate: $0, channels: 1)
                }
            }
            // Same racy internal validation as prewarm's install — catch,
            // don't crash (see prewarmBody).
            let exception = ObjCExceptionCatcher.catchException {
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
                    self?.processTapBuffer(buffer)
                }
            }
            if let exception {
                DebugTimings.persist("MIC recovery installTap raised \(exception.name.rawValue)")
                throw RecorderError.deviceFormatMismatch
            }
            tapInstalled = true
            do {
                try engine.start()
                DebugTimings.persist(String(format: "MIC recovered at rate=%.0f", format.sampleRate))
            } catch {
                DebugTimings.persist("MIC recovery failed: \((error as NSError).code)")
                throw RecorderError.deviceFormatMismatch
            }
        }
    }

    /// The converter for `format`, rebuilt when the live format drifts from
    /// the one we last built for. Internal so the capture extension can use it.
    /// Runs on the tap (audio) thread while invalidate() resets the same
    /// fields from the main actor — every access goes through bufferQueue
    /// (race finding, 2026-08-25). The returned local reference keeps the
    /// converter alive even if invalidate() nils the property mid-buffer.
    func converter(for format: AVAudioFormat) -> AVAudioConverter? {
        bufferQueue.sync {
            if let converter, converterSourceFormat == format { return converter }
            guard let built = AVAudioConverter(from: format, to: targetFormat) else {
                alog.error("no converter from \(format)")
                return nil
            }
            alog.info("converter rebuilt for \(format)")
            converter = built
            converterSourceFormat = format
            return built
        }
    }

    func processTapBuffer(_ buffer: AVAudioPCMBuffer) {
        // Discard buffers when not actively recording. Synchronized read:
        // invalidate() flips this from the main actor mid-capture on a
        // device switch (race finding, 2026-08-25).
        guard bufferQueue.sync(execute: { isCapturing }) else { return }

        // The buffer's own format is authoritative — it cannot be stale the way
        // a format captured at prewarm time can (W20: AirPods pin crash).
        guard buffer.format.sampleRate > 0,
              let converter = converter(for: buffer.format) else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate

        var localPeak: Float = 0
        var sumSquares: Float = 0
        var rms: Float = 0
        if let ch0 = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            for i in 0..<frames {
                let sample = ch0[i]
                let magnitude = abs(sample)
                if magnitude > localPeak { localPeak = magnitude }
                sumSquares += sample * sample
            }
            bufferQueue.async {
                if localPeak > self.inputPeak { self.inputPeak = localPeak }
            }
            // Meter on RMS, not peak: a built-in laptop mic at default gain
            // peaks above the meter's ceiling on nearly every speech buffer,
            // pinning the HUD bars at max. RMS tracks the voice envelope.
            rms = frames > 0 ? sqrt(sumSquares / Float(frames)) : 0
            emitLevel(rms: rms)
        }

        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else { return }

        var error: NSError?
        var fed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, statusPtr in
            if fed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            fed = true
            statusPtr.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            alog.error("convert error: status=\(status.rawValue) err=\(error?.localizedDescription ?? "nil")")
            return
        }

        guard let int16Data = outputBuffer.int16ChannelData?[0] else { return }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Data, count: byteCount)
        let sampleRate = buffer.format.sampleRate
        bufferQueue.async {
            self.bufferCapturedAudio(data, byteCount: byteCount, localPeak: localPeak,
                                     rms: rms, sampleRate: sampleRate)
        }
    }

    /// Appends converted audio to `pcmBuffer` and fires the ready/real-signal
    /// callbacks — always called on `bufferQueue`.
    private func bufferCapturedAudio(_ data: Data, byteCount: Int, localPeak: Float,
                                     rms: Float, sampleRate: Double) {
        guard isCapturing else { return }
        guard pcmBuffer.count + data.count <= Self.maxRecordingBytes else {
            if !droppedOverflow {
                droppedOverflow = true
                alog.error("recording exceeded \(Self.maxRecordingBytes) bytes — discarding further audio. Release the hotkey.")
            }
            return
        }
        pcmBuffer.append(data)
        segmentIfDue(rms: rms)

        // Fire the "ready" cue on the very first callback, unconditionally —
        // responsiveness over precision. A Bluetooth mic may still be mid
        // SCO-handshake here (silence for another ~1-1.5s); the slow-signal
        // check below surfaces a one-time suggestion to switch mics when
        // that actually happens, instead of delaying every recording's
        // feedback to guard against it.
        if !capturedAnyFrame {
            capturedAnyFrame = true
            noteFirstFrame(sampleRate: sampleRate)
            alog.info("first frame captured (\(byteCount) bytes) — firing onCaptureReady")
            if let cb = onCaptureReady {
                DispatchQueue.main.async(execute: cb)
            } else {
                alog.error("first frame but onCaptureReady is nil")
            }
        }

        // Independently track how long real signal (above the noise floor,
        // sustained across a few buffers to ignore an AirPods connect click)
        // takes to arrive, and fire onRealSignalConfirmed the first time it does.
        if localPeak > Self.captureReadyPeakFloor {
            consecutiveLoudBuffers += 1
        } else {
            consecutiveLoudBuffers = 0
        }
        if !reportedRealSignal && consecutiveLoudBuffers >= requiredLoudBuffers {
            reportedRealSignal = true
            let elapsed = recordingArmedAt.map { Date().timeIntervalSince($0) } ?? 0
            alog.info("real signal confirmed after \(elapsed)s")
            if let cb = onRealSignalConfirmed {
                DispatchQueue.main.async(execute: cb)
            } else {
                alog.error("real signal confirmed but onRealSignalConfirmed is nil")
            }
        }
    }
}

// Moved out of AudioRecorder.swift for the swiftlint file-length cap (same
// pattern as this file itself).
extension AudioRecorder {
    enum RecorderError: LocalizedError {
        case micDenied
        case converterFailed
        case noInput
        case deviceFormatMismatch

        var errorDescription: String? {
            switch self {
            case .deviceFormatMismatch:
                return "The selected microphone couldn't be started at its own format"
            case .micDenied: return "Microphone permission denied"
            case .converterFailed: return "Failed to create audio converter"
            case .noInput: return "No audio input device available"
            }
        }
    }

    // Pre-warm: install tap + briefly start/stop the engine so the audio
    // subsystem (driver, format negotiation, AU graph) is warm. Mic indicator
    // turns off as soon as we stop the engine. Subsequent start() calls are
    // ~100 ms instead of the cold-start ~2 s.
    /// - Parameter keepRunning: leave the engine RUNNING at the end instead of
    ///   the usual stop. Used by the silent pre-warm (`beginWarmHold`), where
    ///   stopping would drop the Bluetooth link this whole exercise exists to
    ///   bring up. Callers must have muted the process first.
    func prewarm(keepRunning: Bool = false) async throws {
        // One prewarm at a time. The body SUSPENDS (pin settle, format poll);
        // a quick release-and-repress lands here mid-suspension, and running
        // a second body races both to installTap on the same node — the loser
        // is an uncatchable NSException (crash report 2026-08-05-120316).
        // Joining also serves the joiner: the work it needs is being done.
        if let task = prewarmTask { return try await task.value }
        guard !isPrewarmed else { return }
        let task = Task { try await self.prewarmBody(keepRunning: keepRunning) }
        prewarmTask = task
        defer { prewarmTask = nil }
        try await task.value
    }

    private func prewarmBody(keepRunning: Bool) async throws {
        let granted = await requestPermission()
        guard granted else { throw RecorderError.micDenied }

        // AVAudioEngine.inputNode raises an uncatchable Obj-C NSException
        // ("inputNode != nullptr || outputNode != nullptr") — a hard SIGABRT,
        // not a Swift-catchable error — when the machine has no audio input
        // device at all (mic removed/unavailable, or a transient no-default
        // state). Sentry APPLE-IOS-K. Check first and fail gracefully.
        guard Self.hasAudioInput() else { throw RecorderError.noInput }

        // Every await below is a chance for an invalidate() to replace the
        // engine; touching the OLD engine's node afterwards is an uncatchable
        // NSException (crash report 2026-08-05-1151). So: snapshot the engine,
        // checkpoint after each await, and restart the attempt on a mismatch.
        for attempt in 0..<3 {
            if attempt > 0 {
                alog.info("engine replaced mid-prewarm — restarting on the fresh engine (attempt \(attempt + 1))")
            }
            let engineAtStart = engine
            // Accessing inputNode instantiates the input unit and prepare()
            // initializes it — both required before the unit can be pinned.
            _ = engine.inputNode
            engine.prepare()
            let pinnedDeviceID = pinPreferredInputIfSet()
            if pinnedDeviceID != nil {
                // Wait out the pin's config-change echo BEFORE the tap
                // exists — it lands as a harmless absorb instead of orphaning
                // the tap (observed at 116-133 ms; see pinEchoSettleNs).
                try? await Task.sleep(nanoseconds: Self.pinEchoSettleNs)
                guard engine === engineAtStart else { continue }
            }
            let input = engine.inputNode

            // Usability only — no prediction about what the device will
            // accept. engine.start() is the authority; -10868 is recovered
            // from below.
            let inputFormat = try await usableInputFormat(input)
            guard engine === engineAtStart else { continue }
            alog.info("input format: \(inputFormat)")

            // THE pin fix: the input node inherits its format from the
            // process's default-device aggregate, clocked by the default
            // OUTPUT device — so `format: nil` on a pinned tap adopts a rate
            // the pinned mic may not run, and the unit fails to initialize
            // (-10868; every "Mic didn't start" since the first report). An
            // explicit tap format at the PINNED device's own nominal rate
            // makes AVAudioEngine bridge the two — harness-verified for a
            // default 48 kHz mic and a non-default 32 kHz one alike (full
            // story: commit message). Unpinned keeps nil: the node's format
            // is the truth there. The catcher below stays as the backstop
            // for races invisible from outside; removeTap is a safe no-op.
            let tapFormat: AVAudioFormat? = pinnedDeviceID.flatMap { id in
                AudioInputDevice.nominalSampleRate(id).flatMap {
                    AVAudioFormat(standardFormatWithSampleRate: $0, channels: 1)
                }
            }
            let exception = ObjCExceptionCatcher.catchException {
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
                    self?.processTapBuffer(buffer)
                }
            }
            if let exception {
                alog.error("installTap raised \(exception.name.rawValue): \(exception.reason ?? "<no reason>") — rebuilding and retrying")
                rebuildEngineForDeviceChange()
                continue
            }
            tapInstalled = true

            engine.prepare()
            try startEngineRecoveringFormatMismatch()
            if keepRunning {
                isPrewarmed = true
                alog.info("engine pre-warmed (left running for a warm hold)")
                return
            }
            engine.stop()         // release mic so indicator stays off when idle
            isPrewarmed = true
            alog.info("engine pre-warmed (stopped, caches warm)")
            return
        }
        alog.error("prewarm gave up after 3 engine replacements")
        throw RecorderError.noInput
    }
}
