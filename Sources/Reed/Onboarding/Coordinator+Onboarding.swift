import AppKit
import SwiftUI

/// Onboarding window plumbing. Lives in its own file so Coordinator.swift
/// doesn't balloon past the swiftlint file-length cap; conceptually these are
/// just two more methods on Coordinator.
extension Coordinator {
    /// Show the first-launch onboarding window. Triggered automatically on a
    /// truly-fresh install (see `Coordinator.init`). Once dismissed it never
    /// shows again — by design, the user asked for a single one-shot welcome
    /// experience with no re-entry point.
    ///
    /// No hardware gate (2026-09-06): the build is arm64 only, so an Intel
    /// Mac cannot open Reed at all and a Rosetta launch cannot exist. The OS
    /// version gates nothing (macOS 14–25 = Basic cleanup fallback, already
    /// automatic).
    func openOnboarding() {
        if onboardingWindow == nil {
            // Sidebar layout — 256px sidebar + content area, fixed at the
            // mock's approved dimensions. Non-resizable: the layout's grid
            // assumes this size.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            // Title bars are hidden on every window: the title survives only
            // as the system name (Mission Control / VoiceOver); the traffic
            // lights float over the charcoal sidebar. Mirrors openSettings.
            window.title = "Set up Reed"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            // Committed light palette (charcoal rail + warm-greige content);
            // pin to aqua so system dark mode doesn't invert the surfaces.
            window.appearance = NSAppearance(named: .aqua)
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    audio: OnboardingAudio(
                        currentInput: { [weak self] in self?.currentInputDevice },
                        systemDefault: { AudioInputDevice.defaultInput() },
                        pinnable: { AudioInputDevice.pinnableDevices() },
                        pin: { [weak self] uid in self?.setPreferredMicrophone(uid: uid) },
                        prewarmHold: { [weak self] in
                            // Bluetooth ONLY. A wired mic needs no profile
                            // switch — its cold start is ~600ms at the first
                            // press — and pre-warming it still engages the
                            // Bluetooth OUTPUT for an instant (AVAudioEngine
                            // binds the input unit to the system default
                            // before the pin lands), which audibly dips the
                            // user's music during onboarding. Someone who
                            // just picked a wired mic did so precisely to
                            // keep their AirPods untouched; honor that.
                            // (A briefly-unconditional version of this call
                            // was premised on a misdiagnosis — the real
                            // culprit was invalidate() summoning the input
                            // node, fixed separately.)
                            guard let self, self.currentMicIsBluetooth else { return }
                            self.recorder.shouldHoldWarm = true
                            Task { await self.recorder.beginWarmHold() }
                        }
                    )
                ) { [weak self] in
                    self?.onboardingWindow?.close()
                }
            )
            releaseOnClose(window, from: \.onboardingWindow) {
                // Closing DEFERS, it does not complete (P12 follow-up,
                // 2026-08-07 — the old mark-complete-on-close let a red-button
                // dismissal skip terms acceptance, the permission coaching,
                // and the model download; the hotkey then armed a pipeline
                // that could only fail). Setup finishes only via "Get
                // started" or a Skip button; until then the hotkey summons
                // this window back (Coordinator.start's gate). This also
                // subsumes the old quit-vs-dismissal carve-out
                // (`isTerminating`): close persists nothing either way, and
                // the saved step/path always resumes the flow — including in
                // the fresh window the next open builds.
                NSApp.setActivationPolicy(.accessory)
            }
            onboardingWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}
