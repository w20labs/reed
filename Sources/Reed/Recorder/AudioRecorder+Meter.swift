import Foundation

/// The HUD meter's self-calibrating RMS→bar mapping: split out of
/// AudioRecorder.swift to keep it under the swiftlint file-length cap (see
/// AudioRecorder+Capture.swift for the same pattern).
extension AudioRecorder {
    /// The dB window below the rolling reference that the meter renders across.
    static let meterWindowDB = 25.0
    /// Reference decay per tap buffer: ~3 dB/s at the tap's ~12 buffers/s.
    static let meterReferenceDecayDB = 0.26
    /// A buffer meters only if it clears the rolling noise floor by this much —
    /// the silence gate self-calibrates to the chain's gain. (An absolute
    /// -42 dBFS gate read flat on quiet input chains whose speech RMS sat
    /// below it while peaks still passed the recording gate.)
    static let meterGateDB = 8.0
    /// The decaying reference never drops below noise floor + this headroom.
    static let meterReferenceHeadroomDB = 12.0
    /// Only buffers within this band above the floor pull it up — louder
    /// buffers are speech and must not raise the floor.
    static let meterNoiseBandDB = 15.0
    /// Floor rise per near-floor buffer: ~0.5 dB/s at ~12 buffers/s, so a
    /// changed room (AC kicks in) recalibrates within a minute.
    static let meterNoiseRiseDB = 0.04
    /// Hard lower bound so a digitally-dead channel can't wind the floor to
    /// -120 and meter dither blips.
    static let meterNoiseFloorMinDB = -90.0
    /// The reference attacks this far ABOVE the loudest buffer, so typical
    /// speech rides mid-window and only genuine peaks hit full height — with
    /// the reference at the speech level itself, most bars pinned near max.
    static let meterAttackHeadroomDB = 3.0

    /// Push the current mic level to the HUD meter (main thread). Self-
    /// calibrating: the buffer's RMS dB is normalized against the session's
    /// rolling speech reference, so the wave reads the same at laptop or desk
    /// distance, on hot or quiet mics — honest metering (the #1 dictation
    /// anxiety is "is it hearing me?"), and silent input still sits flat.
    /// RMS, not peak: peak pins on nearly every speech buffer at default gain.
    /// No-op when nobody is listening. Called from AudioRecorder+Capture.
    func emitLevel(rms: Float) {
        // The floor/reference are tracked even with no HUD listener (latency
        // step 2): the live segmenter's speech gate reads the same noise
        // floor, and a bench or a closed HUD must not blind it.
        let db = rms > 1e-6 ? 20 * log10(Double(rms)) : -120
        let norm: Float = bufferQueue.sync {
            // Noise floor: instant drop to any quieter buffer; only near-floor
            // buffers creep it up, so speech never raises it into its own range.
            if db < meterNoiseFloorDB {
                meterNoiseFloorDB = max(db, Self.meterNoiseFloorMinDB)
            } else if db < meterNoiseFloorDB + Self.meterNoiseBandDB {
                meterNoiseFloorDB = min(db, meterNoiseFloorDB + Self.meterNoiseRiseDB)
            }
            // Fast attack — the reference jumps straight to any louder level —
            // and slow (~3 dB/s) decay so it tracks a speaker who trails off.
            // Never below floor + headroom, so long silence can't wind the
            // window down into room-noise territory.
            meterReferenceDB = db + Self.meterAttackHeadroomDB > meterReferenceDB
                ? db + Self.meterAttackHeadroomDB
                : max(meterNoiseFloorDB + Self.meterReferenceHeadroomDB,
                      meterReferenceDB - Self.meterReferenceDecayDB)
            return Self.meterNorm(rmsDB: db, referenceDB: meterReferenceDB,
                                   noiseFloorDB: meterNoiseFloorDB)
        }
        // Gated silence emits NOTHING: the wave freezes exactly as it was the
        // moment speech stopped. A decaying tail here scroll-rendered as a
        // collapsing wedge ("the rectangle"); recording start still reads
        // flat because the bars start flat.
        guard norm > 0, let cb = onLevel else { return }
        DispatchQueue.main.async { cb(norm) }
    }

    /// RMS dB → 0…1 meter value, relative to the rolling speech reference: a
    /// 25 dB window ending at the reference, with a ^0.75 curve. Pure — the
    /// stateful reference and floor live on the recorder.
    static func meterNorm(rmsDB: Double, referenceDB: Double, noiseFloorDB: Double) -> Float {
        // At or below the session's own room tone + margin is silence,
        // whatever the reference — a decayed reference must never amplify
        // room noise into a fake wave, at any input gain.
        guard rmsDB > noiseFloorDB + meterGateDB else { return 0 }
        let linear = max(0, min(1, (rmsDB - (referenceDB - meterWindowDB)) / meterWindowDB))
        // ^1.3 spreads syllable variation across the bar range — a lifting
        // curve (^0.75) compressed everything into the top of the bars.
        return Float(pow(linear, 1.3))
    }

}
