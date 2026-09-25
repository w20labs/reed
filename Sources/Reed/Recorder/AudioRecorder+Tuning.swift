import Foundation

/// The measured, hand-tuned thresholds of the capture path — split from
/// AudioRecorder.swift for the swiftlint file-length cap. Each carries the
/// field story that produced its value; change them only with a new one.
extension AudioRecorder {
    // Cap a single recording at 5 minutes — long enough for any reasonable
    // dictation, short enough that a stuck hotkey or runaway state can't
    // OOM the machine. At 16 kHz mono int16, 5 min = ~9.6 MB.
    static let maxRecordingBytes = 16_000 * 2 * 60 * 5

    // Peak level below which a recording counts as "silence / said nothing", so
    // we skip transcription instead of letting Whisper hallucinate "Thank you."
    // -35 dBFS ≈ int16 peak 583; real speech peaks far above this even when quiet.
    /// Below this output peak the recording is treated as silence. Was -35,
    /// which binned soft real speech (user-reported "No audio captured" after
    /// a genuine dictation); -42 still sits far above true silence (~-60+),
    /// keeping the Whisper-hallucinates-on-silence guard intact.
    static let silenceFloorDB = -42.0

    // Peak (float, 0…1, raw input domain) below which a captured buffer counts
    // as "no real signal yet" for onCaptureReady purposes. Bluetooth mics
    // (AirPods) hand the tap well-formed but exact-zero buffers for ~1.5s while
    // the SCO link negotiates — "we got a callback" is not proof the mic is
    // live, but any signal above the electrical/room noise floor is. Far below
    // real speech or even quiet room tone, so built-in/wired mics (which have
    // real signal from frame 1) fire onCaptureReady just as fast as before.
    static let captureReadyPeakFloor: Float = 1e-4

    // Consecutive above-floor tap buffers required to count real signal as
    // "arrived", used to fire onRealSignalConfirmed. Every AirPods reconnect
    // (each engine.start()) emits a single loud "connect click" buffer —
    // sometimes >20% of full scale — immediately followed by a return to
    // exact-zero for the rest of the SCO warm-up. A one-buffer threshold
    // check fires on that click. Requiring the signal to hold for a couple
    // of buffers (~150-250ms at the observed 48kHz/4096 tap size) filters
    // the isolated click.
    static let captureReadyConsecutiveBuffers = 3
}
