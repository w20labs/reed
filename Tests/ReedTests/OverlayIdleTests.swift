import AppKit
import SwiftUI
import XCTest
@testable import Reed

/// The HUD panel is ordered out between dictations, not destroyed. Whatever
/// its view still mounts keeps running: after a dictation the view model sat
/// at idle + justFinished, so the ring's repeatForever spin animated inside
/// the hidden panel until the next press (~20% CPU idle, plus WindowServer;
/// 0.3.2, 2026-10-09). A hidden pill mounts no icon (the parts that animate),
/// but stays mounted itself: emptying it made the next show lay it out from
/// nothing, off-centre and then a jump (0.3.3, 2026-10-10).
final class OverlayIdleTests: XCTestCase {

    /// Every state the pill can be left in when the panel hides, and whether
    /// it shows an icon (ring, waveform or warning) on screen.
    private static let states: [(Coordinator.State, justFinished: Bool, micIsPreparing: Bool, icon: Bool)] = [
        (.idle, justFinished: true, micIsPreparing: false, icon: true),
        (.idle, justFinished: false, micIsPreparing: false, icon: false),
        (.warming, justFinished: false, micIsPreparing: true, icon: true),
        (.warming, justFinished: false, micIsPreparing: false, icon: true),
        (.recording, justFinished: false, micIsPreparing: false, icon: true),
        (.preparingModel, justFinished: false, micIsPreparing: false, icon: true),
        (.transcribing, justFinished: false, micIsPreparing: false, icon: true),
        (.injecting, justFinished: false, micIsPreparing: false, icon: true),
        (.error("Microphone unavailable"), justFinished: false, micIsPreparing: false, icon: true),
        (.notice("Nothing to write"), justFinished: false, micIsPreparing: false, icon: false),
    ]

    @MainActor
    private func renderedSize(_ viewModel: OverlayViewModel) -> NSSize {
        let host = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @MainActor
    func testHiddenPillKeepsItsBodyButDropsItsIcon() {
        for (state, justFinished, micIsPreparing, icon) in Self.states {
            let viewModel = OverlayViewModel()
            viewModel.state = state
            viewModel.justFinished = justFinished
            viewModel.micIsPreparing = micIsPreparing

            viewModel.isOnScreen = true
            let shown = renderedSize(viewModel)
            viewModel.isOnScreen = false
            let hidden = renderedSize(viewModel)

            XCTAssertGreaterThan(hidden.width, 0, "hidden, \(state) must keep the pill mounted")
            XCTAssertGreaterThan(hidden.height, 0, "hidden, \(state) must keep the pill mounted")
            if icon {
                XCTAssertLessThan(hidden.width, shown.width, "hidden, \(state) must not mount its icon")
            } else {
                XCTAssertEqual(hidden.width, shown.width, accuracy: 0.5, "\(state) has no icon to drop")
            }
        }
    }

    @MainActor
    func testOrderOutDropsTheRing() {
        // The production sequence: a dictation lands (idle + the Done beat,
        // ring mounted), then the hide completes.
        let controller = OverlayController()
        controller.viewModel.state = .idle
        controller.viewModel.justFinished = true
        controller.viewModel.isOnScreen = true
        let shown = renderedSize(controller.viewModel)

        controller.didOrderOut()

        XCTAssertFalse(controller.viewModel.isOnScreen)
        let hidden = renderedSize(controller.viewModel)
        XCTAssertGreaterThan(hidden.width, 0)
        XCTAssertLessThan(hidden.width, shown.width)
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
        let size = OverlayController.panelSize
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

/// A panel that hugs the pill cuts its drop shadow off in a straight line,
/// which reads as a grey rectangle around the pill (2026-10-10). Rendered at
/// the panel's size, the pill's shadow must fade out before every edge.
@MainActor
final class OverlayShadowRoomTests: XCTestCase {
    func testShadowFadesBeforeThePanelEdges() throws {
        _ = NSApplication.shared
        let states: [Coordinator.State] = [.recording, .preparingModel, .error("Mic wasn't ready")]
        for state in states {
            let controller = OverlayController()
            controller.viewModel.state = state
            controller.viewModel.isOnScreen = true
            let host = controller.makeContentView()
            host.frame = NSRect(origin: .zero, size: OverlayController.panelSize)
            host.layoutSubtreeIfNeeded()
            let edge = try maxEdgeAlpha(host)
            XCTAssertLessThan(edge, 0.02, "\(state): the shadow is cut off at the panel edge")
        }
    }
}

/// The most opaque pixel on the outermost ring of `view`'s rendering.
@MainActor
func maxEdgeAlpha(_ view: NSView) throws -> CGFloat {
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let width = rep.pixelsWide, height = rep.pixelsHigh
    var edge: CGFloat = 0
    for x in 0..<width {
        edge = max(edge, rep.colorAt(x: x, y: 0)?.alphaComponent ?? 0, rep.colorAt(x: x, y: height - 1)?.alphaComponent ?? 0)
    }
    for y in 0..<height {
        edge = max(edge, rep.colorAt(x: 0, y: y)?.alphaComponent ?? 0, rep.colorAt(x: width - 1, y: y)?.alphaComponent ?? 0)
    }
    return edge
}
