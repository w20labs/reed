import AppKit
import SwiftUI
import XCTest
@testable import Reed

/// The HUD panel is ordered out between dictations, not destroyed. Whatever
/// its view still mounts keeps running: after a dictation the view model sat
/// at idle + justFinished, so the ring's repeatForever spin animated inside
/// the hidden panel until the next press (~20% CPU idle, plus WindowServer;
/// 0.3.2, 2026-10-09). These pin that a hidden panel mounts nothing.
final class OverlayIdleTests: XCTestCase {

    /// Every state the pill can be left in when the panel hides, including the
    /// ones that mount the spinning ring.
    private static let states: [(Coordinator.State, justFinished: Bool, micIsPreparing: Bool)] = [
        (.idle, justFinished: true, micIsPreparing: false),
        (.idle, justFinished: false, micIsPreparing: false),
        (.warming, justFinished: false, micIsPreparing: true),
        (.warming, justFinished: false, micIsPreparing: false),
        (.recording, justFinished: false, micIsPreparing: false),
        (.preparingModel, justFinished: false, micIsPreparing: false),
        (.transcribing, justFinished: false, micIsPreparing: false),
        (.injecting, justFinished: false, micIsPreparing: false),
        (.error("Microphone unavailable"), justFinished: false, micIsPreparing: false),
        (.notice("Nothing to write"), justFinished: false, micIsPreparing: false),
    ]

    @MainActor
    private func renderedSize(_ viewModel: OverlayViewModel) -> NSSize {
        let host = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @MainActor
    func testHiddenPanelMountsNothing() {
        for (state, justFinished, micIsPreparing) in Self.states {
            let viewModel = OverlayViewModel()
            viewModel.state = state
            viewModel.justFinished = justFinished
            viewModel.micIsPreparing = micIsPreparing

            viewModel.isOnScreen = true
            XCTAssertGreaterThan(renderedSize(viewModel).width, 0, "on screen, \(state) must render the pill")

            viewModel.isOnScreen = false
            XCTAssertEqual(renderedSize(viewModel), .zero, "hidden, \(state) must mount nothing")
        }
    }

    @MainActor
    func testOrderOutUnmountsThePill() {
        // The production sequence: a dictation lands (idle + the Done beat,
        // ring mounted), then the hide completes.
        let controller = OverlayController()
        controller.viewModel.state = .idle
        controller.viewModel.justFinished = true
        controller.viewModel.isOnScreen = true
        XCTAssertGreaterThan(renderedSize(controller.viewModel).width, 0)

        controller.didOrderOut()

        XCTAssertFalse(controller.viewModel.isOnScreen)
        XCTAssertEqual(renderedSize(controller.viewModel), .zero)
    }
}

/// Unmounting the hidden pill must not resize the panel: the hosting view
/// used to size the panel to its content, so a hidden (empty) pill collapsed
/// it to 0×0 and the next show centred that empty frame — the pill appeared
/// right of centre, then jumped left while the panel grew (0.3.3, 2026-10-10).
final class OverlayPanelSizeTests: XCTestCase {
    @MainActor
    func testPanelKeepsItsSizeAcrossHideAndShow() {
        _ = NSApplication.shared
        let controller = OverlayController()
        let size = NSSize(width: 316, height: 84)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = controller.makeContentView()
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            panel.contentView?.layoutSubtreeIfNeeded()
        }

        controller.viewModel.state = .idle
        controller.viewModel.justFinished = true
        controller.viewModel.isOnScreen = true
        settle()
        XCTAssertEqual(panel.frame.size, size)

        controller.didOrderOut()
        settle()
        XCTAssertEqual(panel.frame.size, size, "a hidden pill must not collapse the panel")

        controller.viewModel.state = .recording
        controller.viewModel.isOnScreen = true
        settle()
        XCTAssertEqual(panel.frame.size, size, "showing again must not resize the panel")
    }
}
