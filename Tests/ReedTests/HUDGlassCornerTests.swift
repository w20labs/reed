import AppKit
import SwiftUI
import XCTest
@testable import Reed

/// The HUD glass is a behind-window blur, composited by the window server
/// from the view's whole rectangle; SwiftUI's rounded clip doesn't reach it,
/// so its square corners showed as a shade around the pill (2026-10-10).
/// The blur view must carry its own rounded mask.
@MainActor
final class HUDGlassCornerTests: XCTestCase {
    private func blurViews(in view: NSView) -> [NSVisualEffectView] {
        let own = (view as? NSVisualEffectView).map { [$0] } ?? []
        return own + view.subviews.flatMap(blurViews)
    }

    private func mounted(_ root: some View) -> NSView {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 120)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func assertRoundedMask(_ view: NSVisualEffectView?, _ what: String) throws {
        let mask = try XCTUnwrap(view?.maskImage, "\(what): the blur has no mask, so its square corners show")
        var rect = NSRect(origin: .zero, size: mask.size)
        let cg = try XCTUnwrap(mask.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.05, "\(what): corner must be cut")
        XCTAssertEqual(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0, 1, accuracy: 0.05)
    }

    func testPillGlassIsRounded() throws {
        let viewModel = OverlayViewModel()
        viewModel.state = .recording
        viewModel.isOnScreen = true
        let views = blurViews(in: mounted(OverlayView(viewModel: viewModel)))
        XCTAssertEqual(views.count, 1)
        try assertRoundedMask(views.first, "pill")
    }

    func testToastGlassIsRounded() throws {
        let views = blurViews(in: mounted(Text("Microphone unavailable").modifier(HUDCard())))
        XCTAssertEqual(views.count, 1)
        try assertRoundedMask(views.first, "toast")
    }
}

/// The toast panel is sized to its content's fitting size, so the card's
/// shadow used to be cut off on every side: a grey rectangle around it
/// (2026-10-10). At its fitting size the shadow must fade before every edge.
@MainActor
final class HUDCardShadowRoomTests: XCTestCase {
    func testToastShadowFadesBeforeThePanelEdges() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Text("Microphone unavailable").hudCard())
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var edge: CGFloat = 0
        for x in 0..<rep.pixelsWide {
            edge = max(edge, rep.colorAt(x: x, y: 0)?.alphaComponent ?? 0, rep.colorAt(x: x, y: rep.pixelsHigh - 1)?.alphaComponent ?? 0)
        }
        for y in 0..<rep.pixelsHigh {
            edge = max(edge, rep.colorAt(x: 0, y: y)?.alphaComponent ?? 0, rep.colorAt(x: rep.pixelsWide - 1, y: y)?.alphaComponent ?? 0)
        }
        XCTAssertLessThan(edge, 0.02, "the toast's shadow is cut off at the panel edge")
    }
}
