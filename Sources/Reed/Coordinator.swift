import AppKit
import Foundation
import KeyboardShortcuts
import SwiftUI

let log = Log(category: "pipeline")

@MainActor
final class Coordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case warming        // hotkey held, audio engine starting up, mic not yet live
        case recording
        case preparingModel // cold speech-model load (excluded from the ASR deadline)
        case transcribing
        case injecting
        case error(String)
        // Soft outcome, not an error: the dictation produced nothing to write
        // (silence, a cough). Muted glyph-less pill, no menubar breadcrumb.
        case notice(String)
    }

    static let shared = Coordinator()

    @Published var state: State = .idle
    @Published var lastTranscript: String = ""
    /// Live mic level (0…1) for the HUD meter; 0 when not recording.
    @Published var inputLevel: Float = 0
    /// Debug (design rule ⑩, `reed.debugTimings`): per-stage timing line for the
    /// just-finished dictation, shown in the Done beat ("asr 0.9s · ai 0.7s").
    @Published var lastTimings: String?
    /// The last unresolved dictation failure, in curated human form. Outlives
    /// the ephemeral error pill: it drives the persistent menubar attention dot
    /// and the in-menu error banner (where the user reads + fixes it), and is
    /// cleared when the next dictation starts or the user dismisses it.
    /// True while `.warming` on a Bluetooth input, so the HUD can say
    /// "Preparing mic…" rather than claim Listening at a waveform while the
    /// A2DP->HFP switch is still in progress. Cleared the moment the mic is
    /// genuinely live, and on every path that leaves warming.
    @Published var micIsPreparing = false
    @Published var activeError: DictationError?
    /// Selected input device's UID, or nil for "system default". Mirrors
    /// `AudioInputDevice.preferredUIDDefaultsKey` in UserDefaults so the menu
    /// bar picker, Settings picker, and the mic-warning toast all read/write
    /// the same live, observable value.
    @Published var preferredMicrophoneUID: String?

    private let overlay = OverlayController()
    // Push-to-talk hold (see ModifierHoldMonitor). Targets whichever modifier
    // combo the user picked (default ⌃⌥); stands down in custom-shortcut mode.
    // Internal, not private: tests assert on `holdMonitor.currentTrigger` to
    // verify the hold suspends while a HotkeyRecorderField is recording
    // (see configureHoldMonitor).
    let holdMonitor = ModifierHoldMonitor(trigger: PushToTalkTrigger.current.modifiers)
    /// How many `HotkeyRecorderField`s are currently armed (onboarding and
    /// Settings can be open — and recording — side by side). Counted, not a
    /// bool, so one disarming doesn't resume the hold monitor while the
    /// other is still capturing. Internal, not private: read/written from
    /// Coordinator+HoldMonitor.swift. See `configureHoldMonitor`.
    var activeHotkeyRecordings = 0
    /// Bumped by stopAndProcess so an in-flight start() can detect its press
    /// already ended — the prewarm race (2026-08-24): a quick tap during the
    /// cold-start await left the mic armed with the coordinator idle.
    var pressGeneration = 0
    /// Identity for the 4 s error auto-clear (audit 2026-08-25): a stale
    /// clear task from error A must not truncate a newer error B's pill.
    /// Bumped on every scheduled clear AND on every fresh press (start()),
    /// so errors that never schedule one still invalidate older tasks.
    var errorClearGeneration = 0
    /// Whether `onRealSignalConfirmed` has fired for the current recording —
    /// reset at the start of each one. If the user releases the hotkey while
    /// this is still false on a Bluetooth mic, the SCO handshake very likely
    /// ate the whole dictation; `stopAndProcess` uses this to decide whether
    /// to surface `micWarning` instead of silently going idle.
    var realSignalConfirmedForCurrentRecording = false
    /// One transparent restart per press when a config change kills the
    /// capture mid-recording (see handleCaptureInterrupted). Reset when a
    /// press begins.
    var captureRetriedThisPress = false
    // Internal: shared with the Coordinator+Pipeline / +Microphone
    // extensions. (Extensions in other files can't see `private` members.)
    let recorder = AudioRecorder()
    let micWarning = MicWarningController()
    /// Rate limit for the proactive Bluetooth nudge (see maybeNudgeAboutBluetooth).
    let bluetoothNudge = BluetoothNudgePolicy()
    let injector = TextInjector()
    /// Overlapped cleanup bookkeeping for the current press (Coordinator+Overlap).
    let overlap = OverlapSession()
    /// Lever 6: the hold-long keep-warm loop (Coordinator+KeepWarm).
    var keepWarmTask: Task<Void, Never>?
    /// Tickles sent during the current hold (timings line: `warm N`).
    var keepWarmTickles = 0
    /// Built-in vocabulary pass: per-app-run domain state, memory only.
    let corrections = CorrectionSession()

    // Internal, not private: openSettings lives in Coordinator+Presentation
    // (file_length).
    var settingsWindow: NSWindow?
    // Internal: managed by extensions in Onboarding/ and WhatsNew/.
    var onboardingWindow: NSWindow?
    var whatsNewWindow: NSWindow?
    /// Set once `NSApplication.willTerminateNotification` fires. AppKit
    /// closes open windows as part of `-terminate:`, which fires each
    /// window's `willClose` *before* the process exits — so a close handler
    /// that treats close as "the user dismissed this" (onboarding marking
    /// itself complete, What's New marking itself seen) needs this to tell
    /// quitting apart from an actual dismissal. See Coordinator+Onboarding.
    var isTerminating = false

    /// When the current hold began — used to tell "tap released early" (silent
    /// idle is fine) from "the user actually dictated and we lost it" (must
    /// surface an error, never silently drop speech).
    var holdStartedAt: Date?
    /// The press's local-review collector (P16): begun at the press, fed by
    /// the cleanup loop and the release path, ended with the press. See
    /// Coordinator+LocalReview.swift.
    var review: DictationReview?
    // Watchdog for stuck .warming: AVAudioEngine can silently fail to deliver
    // frames (Bluetooth-profile renegotiation, etc.). Cancelled on first audio.
    var warmingWatchdog: Task<Void, Never>?
    static let warmingTimeout: UInt64 = 2_000_000_000  // 2 s
    // Bluetooth needs its own budget: macOS has to switch the device from A2DP
    // to HFP/SCO before a single frame is audible, which routinely takes
    // 0.5-1.5 s. Holding warming open that long against the wired 2 s timeout
    // would turn a normal AirPods connect into "Microphone didn't start".
    static let warmingTimeoutBluetooth: UInt64 = 5_000_000_000  // 5 s

    init() {
        // Not a plain read: drops a pin that names a Bluetooth mic, which
        // older builds allowed and which can only record silence.
        preferredMicrophoneUID = AudioInputDevice.loadPreferredUID()
        // One-time purge of user-supplied provider keys left by earlier builds
        // (that tier was removed 2026-07-22).
        KeyStore.purgeLegacyBYOKeys()
        // One-time purge of what the account, cloud and paid features left
        // behind (removed 2026-09-15).
        LegacyPaidDataPurge.runOnce()
        // Orphaned since #213 removed its toggle; the Cleanup checkbox's
        // localCleanupTier governs every pipeline now (review 2026-08-26,
        // F4). Unconditional: removeObject is an idempotent no-op.
        UserDefaults.standard.removeObject(forKey: "enableCleanup")
        // Prompt at launch ONLY once onboarding is done. While onboarding is
        // due, its Accessibility step owns the ask (a deep link into System
        // Settings); the system alert on top of that is a second asker — and
        // macOS never dismisses that alert on its own, so it lingered over
        // the flow even after the user granted access (hand-test finding).
        let axTrusted = TextInjector.ensureAccessibilityPermission(
            prompt: !OnboardingState.shouldShowOnFirstLaunch())
        log.info("Coordinator init; AXIsProcessTrusted=\(axTrusted); current shortcut: \(KeyboardShortcuts.getShortcut(for: .toggleDictation)?.description ?? "<none>")")

        // Fires before any open window's willClose during quit (verified:
        // -terminate: posts this, then closes windows) — see `isTerminating`.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isTerminating = true
        }

        // Audio engine is NOT prewarmed: starting AVAudioEngine renegotiates
        // the input device's sample rate, producing a brief glitch in other
        // apps sharing it (e.g. video while AirPods are connected). Lazy
        // start on first hotkey press defers that cost. Top-center HUD
        // subscription is non-retaining despite the strong overlay hold.
        overlay.attach(to: self)
        // Live HUD meter: the recorder already marshals this to the main thread.
        recorder.onLevel = { [weak self] level in self?.inputLevel = level }
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            log.info("hotkey keyDown")
            guard let self else { return }
            Task { @MainActor in await self.start() }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            log.info("hotkey keyUp")
            guard let self else { return }
            Task { @MainActor in await self.stopAndProcess() }
        }
        configureHoldMonitor()

        // Fresh installs → onboarding; existing users → What's New once after
        // a version bump.
        Task.detached { [weak self] in
            guard let self else { return }
            if OnboardingState.shouldShowOnFirstLaunch() {
                await MainActor.run { self.openOnboarding() }
                return
            }
            // Fresh installs skip this — OnboardingState.markComplete stamps
            // it seen.
            await MainActor.run { self.showWhatsNewIfNeeded() }
            // A set-up install whose speech model went missing used to be
            // nagged toward Settings here. P15 (DECIDED 2026-09-02): there is
            // nothing to pick any more — ReedApp's launch task repairs it on
            // its own (ModelDownloadController.repairIfNeeded), and NOT from
            // here: every Coordinator() a test constructs runs this task, and
            // a 461 MB download is not a unit test's business (CI, 2026-09-03).
        }
    }

    /// A tab Settings should land on when opened by an error action —
    /// consumed once by SettingsView. Permission errors deep-link to the
    /// Permissions pane.
    @Published var requestedSettingsTab: SettingsTab?

    /// Zero the live meter when capture stops: the recorder's `onLevel` goes
    /// quiet at that point, so `inputLevel` would otherwise freeze at its last
    /// value and the HUD bars would stick mid-height.
    func resetMeter() {
        inputLevel = 0
    }

}
