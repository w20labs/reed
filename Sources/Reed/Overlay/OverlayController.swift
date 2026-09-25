import AppKit
import Combine
import SwiftUI

/// Manages a top-center floating HUD window that mirrors the dictation
/// pipeline's progress (warming / recording / transcribing / injecting).
/// The window is an NSPanel: non-activating, click-through, floats above
/// regular apps, and follows the user across spaces and full-screen apps.
@MainActor
final class OverlayController {
    let viewModel = OverlayViewModel()

    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var hideTask: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var recordingStart: Date?
    private var previousState: Coordinator.State = .idle

    /// Subscribe to a Coordinator's state stream. The controller mirrors
    /// state into its view model and shows/hides the HUD accordingly.
    func attach(to coordinator: Coordinator) {
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handle(state: state) }
            .store(in: &cancellables)
        coordinator.$inputLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.viewModel.level = level }
            .store(in: &cancellables)
        coordinator.$lastTimings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] timings in self?.viewModel.timings = timings }
            .store(in: &cancellables)
        coordinator.$micIsPreparing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] preparing in self?.viewModel.micIsPreparing = preparing }
            .store(in: &cancellables)
        coordinator.$activeError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in self?.viewModel.errorIsHard = error?.severity == .hard }
            .store(in: &cancellables)
    }

    private func handle(state: Coordinator.State) {
        let previous = previousState
        previousState = state
        viewModel.state = state
        switch state {
        case .idle:
            stopElapsed()
            // If we just landed a dictation, hold a brief check + "Done" beat so
            // the success reads, rather than the pill blanking to idle instantly.
            let finished: Bool
            switch previous {
            case .transcribing, .injecting: finished = true
            default: finished = false
            }
            viewModel.justFinished = finished
            cancelHide()
            if finished {
                show()
                // Debug timings linger so the breakdown is readable (design
                // rule ⑩).
                let linger: TimeInterval = viewModel.timings != nil ? 3.0 : 0.6
                scheduleHide(after: linger)
            } else {
                scheduleHide(after: 0.4)
            }
        case .error:
            stopElapsed()
            viewModel.justFinished = false
            cancelHide()
            show()
            scheduleHide(after: 3.0)
        case .notice:
            // Soft outcome ("Nothing to write"): linger just long enough to
            // register, well short of an error's 3 s.
            stopElapsed()
            viewModel.justFinished = false
            cancelHide()
            show()
            scheduleHide(after: 1.0)
        case .recording:
            viewModel.justFinished = false
            startElapsed()
            cancelHide()
            show()
        case .warming, .preparingModel, .transcribing, .injecting:
            viewModel.justFinished = false
            stopElapsed()
            cancelHide()
            show()
        }
    }

    private func startElapsed() {
        if elapsedTimer != nil { return }
        recordingStart = Date()
        viewModel.elapsed = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let start = self.recordingStart else { return }
                self.viewModel.elapsed = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func stopElapsed() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStart = nil
        // Clear the displayed count immediately, not just when the next
        // recording starts — otherwise the HUD shows the previous take's
        // final elapsed value throughout the whole next .warming phase.
        viewModel.elapsed = 0
    }

    private func show() {
        // No running NSApplication means no session to present into — a unit
        // test, or a headless CI runner. Correction to the claim this comment
        // originally made: the 2026-07-29 CI hang was NOT caused by this view
        // (root cause was Sparkle's modal startup-error alert — see
        // Updater.init). The hosting view was rendering INSIDE that modal's
        // run loop, which is what the first stack sample showed and what
        // misled the diagnosis. The guard stays on its own merits: a test
        // process has nobody to show a HUD to, and headless UI pollutes any
        // future hang sample exactly the way it polluted that one.
        guard NSApplication.shared.isRunning else { return }
        if panel == nil { buildPanel() }
        guard let panel else { return }

        repositionForCurrentScreen()

        if panel.isVisible && panel.alphaValue > 0.95 { return }
        panel.alphaValue = panel.isVisible ? panel.alphaValue : 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1.0
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.20
                ctx.allowsImplicitAnimation = true
                panel.animator().alphaValue = 0
            },
            completionHandler: {
                if panel.alphaValue < 0.05 { panel.orderOut(nil) }
            }
        )
    }

    private func scheduleHide(after seconds: TimeInterval) {
        cancelHide()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.hide() }
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func buildPanel() {
        // Wide enough for the pill plus the elapsed timer.
        // Panel = pill maxWidth (300) + 16 slack, mirroring the original ratio so
        // the fixed-width pill stays centred under the screen midline.
        let size = NSSize(width: 316, height: 84)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // shadow is rendered inside SwiftUI
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.contentView = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        self.panel = panel
    }

    /// Position centred horizontally and ~80 pt below the top of whichever
    /// screen currently has the mouse cursor. Falls back to the main screen.
    private func repositionForCurrentScreen() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
        guard let screen else { return }

        let frame = screen.frame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.maxY - 80 - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
