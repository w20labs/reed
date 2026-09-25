import AppKit
import Combine
import SwiftUI

/// Drives Reed's menubar item icon. Pre-renders the brand-mark frames at
/// app launch (yielding between each render so we never block the main
/// thread) and swaps between them with a plain `Timer` while the pipeline
/// is in a "live" state (warming or recording). This is the conservative
/// alternative to the earlier TimelineView-based attempt, which starved
/// the main thread and caused KeyboardShortcuts' keyUp events to be
/// dropped — leaving the engine recording forever.
@MainActor
final class MenuBarIconCache: ObservableObject {
    static let shared = MenuBarIconCache()

    /// Number of phase samples around the sine cycle.
    static let frameCount = 12

    /// Resting brand mark.
    @Published private(set) var idle: NSImage = placeholder()

    /// Resting brand mark with the amber attention dot baked in — shown while
    /// `activeError` is set. Baked into the image because MenuBarExtra
    /// template-flattens label content, making a SwiftUI overlay dot invisible.
    @Published private(set) var errorBadged: NSImage = placeholder()

    /// Animated frames cycled through during warming + recording.
    @Published private(set) var frames: [NSImage] = []

    private var prepared = false

    /// Kicks off the pre-render. Safe to call multiple times.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Render the idle frame first so the menubar has something
            // representative as fast as possible.
            await Task.yield()
            self.idle = ReedIcon.makeMenuBarImage()
            self.errorBadged = ReedIcon.makeMenuBarErrorImage()

            var built: [NSImage] = []
            for i in 0..<Self.frameCount {
                let phase = Double(i) / Double(Self.frameCount)
                let img = ReedIcon.makeMenuBarImage(
                    heights: ReedIcon.animatedHeights(phase: phase)
                )
                built.append(img)
                // Yield between renders so a 12-frame batch can't lock up
                // the main thread the way a synchronous batch did before.
                await Task.yield()
            }
            self.frames = built
        }
    }

    /// Tiny pre-baked fallback so MenuBarExtra has *something* to show
    /// for the ~milliseconds before the first real render lands. Drawn
    /// without SwiftUI/ImageRenderer to avoid any first-use cost here.
    private static func placeholder() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.black.setFill()
        let path = NSBezierPath(
            roundedRect: NSRect(x: 4, y: 5, width: 10, height: 8),
            xRadius: 2,
            yRadius: 2
        )
        path.fill()
        image.unlockFocus()
        image.size = NSSize(width: side, height: side)
        image.isTemplate = true
        return image
    }
}

struct MenuBarIconView: View {
    @EnvironmentObject var coordinator: Coordinator
    @ObservedObject private var cache = MenuBarIconCache.shared
    @State private var phase: Int = 0
    @State private var timer: Timer?

    var body: some View {
        Image(nsImage: currentImage)
            .onChange(of: isAnimating) { _, animating in
                if animating {
                    startTimer()
                } else {
                    stopTimer()
                }
            }
    }

    private var isAnimating: Bool {
        switch coordinator.state {
        case .warming, .recording: return true
        case .idle, .preparingModel, .transcribing, .injecting, .error, .notice: return false
        }
    }

    private var currentImage: NSImage {
        if isAnimating, !cache.frames.isEmpty {
            return cache.frames[phase % cache.frames.count]
        }
        // Persistent attention dot: the breadcrumb that survives after the
        // ephemeral error pill fades, pulling the user into the menu (where
        // the error is read + fixed). Clears when the next dictation starts —
        // so the animated frames never need a badged variant.
        if coordinator.activeError != nil {
            return cache.errorBadged
        }
        return cache.idle
    }

    private func startTimer() {
        timer?.invalidate()
        // 10 fps reads as smooth motion without burning cycles.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                phase &+= 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        phase = 0
    }
}
