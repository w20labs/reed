import AppKit
import SwiftUI

@main
struct ReedApp: App {
    @StateObject private var coordinator = Coordinator.shared
    @StateObject private var updater = Updater.shared

    init() {
        // The network guarantee: a process-wide URLProtocol that blocks every
        // host outside the allowlist. Registered first so it's active before
        // any SDK can fire.
        GateURLProtocol.register()
        // Prune the consolidated local log (reed.log) to 72h on every launch —
        // catches a file that sat untouched while the app was closed for days.
        FileLog.trimOnLaunch()
        // Review copies expire on time even after the developer key is gone (P16).
        LocalReviewStore.expireOnLaunch()
        // Reed no longer has telemetry (2026-09-26): clear what the old
        // analytics and crash-report switches left behind, once.
        LegacyTelemetryPurge.runOnce()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(coordinator)
                .environmentObject(updater)
        } label: {
            // Animated brand-mark waveform. Frames are pre-rendered at app
            // launch via MenuBarIconCache (yielding between each render so
            // the main thread is never blocked); the view swaps between
            // them with a plain Timer when warming/recording. This is the
            // conservative replacement for the earlier TimelineView attempt
            // which froze the app.
            MenuBarIconView()
                .environmentObject(coordinator)
                .task {
                    MenuBarIconCache.shared.prepare()
                    // P15 (DECIDED 2026-09-02): one speech model. A set-up
                    // install whose files went missing re-downloads on its
                    // own with the onboarding progress flow; a present one
                    // is prewarmed so the first dictation never pays the
                    // CoreML load (design rule ⑨). Runs on the ASR actor —
                    // never blocks launch.
                    ModelDownloadController.shared.repairIfNeeded()
                    if ModelStore.isSpeechModelInstalled, !ModelDownloadController.shared.isDownloading {
                        try? await ParakeetClient.shared.prepare()
                    }
                    // Existing installs carry ~600 MB of WhisperKit
                    // models nothing uses now — retired once, after
                    // Parakeet has proven to load, and logged.
                    if await ParakeetClient.isReady {
                        let removed = ModelStore.removeUnusedWhisperModels()
                        if !removed.isEmpty { log.info("retired unused WhisperKit models: \(removed.joined(separator: ", "))") }
                    }
                }
        }
        .menuBarExtraStyle(.window)
    }
}
