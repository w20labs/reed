import AppKit
import SwiftUI

/// Reed's brand mark: five vertical capsule bars in a waveform pattern.
/// Used as the glyph inside the app icon, in the menubar popover header,
/// and as the menubar item icon. The shape mirrors the one rendered by
/// `Tools/render-icon.swift` for the on-disk `.icns`, so the visual is
/// consistent everywhere.
struct ReedIcon: View {
    /// Fill color for the bars. Use `.primary` inside the menubar (so it
    /// auto-adapts to light/dark menubar appearance), `.accentColor` inside
    /// the popover header, `.white` when rendered against the gradient bg.
    var fill: Color = .primary

    /// Relative bar heights, all in [0, 1]. Defaults to the static brand mark.
    var heights: [CGFloat] = ReedIcon.defaultHeights

    /// Canonical static heights for the resting brand mark.
    static let defaultHeights: [CGFloat] = [0.50, 0.78, 1.00, 0.78, 0.50]

    /// Returns animated bar heights for the given phase in [0, 1]. Bars are
    /// out of phase with each other so the motion reads as a wave traveling
    /// across, similar to a level meter on a vocal pulse.
    static func animatedHeights(phase: Double) -> [CGFloat] {
        let phaseOffsets: [Double] = [0.0, 0.15, 0.30, 0.45, 0.60]
        return phaseOffsets.map { offset in
            let value = sin((phase + offset) * 2 * .pi)   // [-1, 1]
            // Map to [0.35, 1.0] so bars never collapse fully.
            return CGFloat(0.675 + value * 0.325)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // 5 bars wide + 4 gaps = 7 units of bar + (7 × 0.6) of gap
            // Solve so total width = side, with gap = 0.6 × bar width.
            // 5W + 4 × 0.6W = side  →  W = side / 7.4
            let barWidth = side / 7.4
            let gap = barWidth * 0.6
            HStack(alignment: .center, spacing: gap) {
                ForEach(heights.indices, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(fill)
                        .frame(width: barWidth, height: side * heights[i])
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

/// Full app-icon composition: the brand-mark waveform on the graphite→charcoal
/// gradient tile — the same art as the on-disk `.icns` (Tools/render-icon.swift).
/// Size-agnostic: drop it in a `.frame(width:height:)`. Use this (NOT the bare
/// `ReedIcon`) anywhere the app shows its logo lockup, so it always matches the
/// dock icon — same tile, same colors, never a squeezed tile-less variant.
struct ReedAppIcon: View {
    /// Bar heights; defaults to the resting brand mark. Pass animated heights
    /// for a breathing logo.
    var heights: [CGFloat] = ReedIcon.defaultHeights

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.271, green: 0.271, blue: 0.294),  // #45454B graphite
                            Color(red: 0.161, green: 0.161, blue: 0.176),  // #29292D charcoal
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                // Mark occupies ~55% of the tile, matching render-icon.swift's
                // 230/1024 padding so the in-app icon reads like the dock icon.
                ReedIcon(fill: Color(red: 0.910, green: 0.910, blue: 0.925), heights: heights)
                    .frame(width: side * 0.55, height: side * 0.55)
            }
            .frame(width: side, height: side)
        }
    }
}

extension Color {
    /// The brand mark's in-app color: charcoal #3A3A3C on light surfaces,
    /// soft-tonal #E8E8EC on dark — so the waveform stays visible in both the
    /// (light) Settings window and the system-following menubar popover.
    static let reedMark = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.910, green: 0.910, blue: 0.925, alpha: 1)
            : NSColor(srgbRed: 0.227, green: 0.227, blue: 0.235, alpha: 1)
    })
}

extension ReedIcon {
    /// Pre-renders the brand mark to a template NSImage sized for use as a
    /// menubar item icon. SwiftUI's MenuBarExtra label doesn't auto-template
    /// arbitrary views — colors that depend on the menubar context (.primary
    /// etc.) often resolve to invisible. Rendering to an NSImage and setting
    /// `isTemplate = true` makes macOS treat the alpha channel as the shape
    /// and tint it correctly for light/dark menubars (and inverse states like
    /// when the menu is open).
    /// Every menubar image — idle, animation frames, and the error variant —
    /// shares one canvas with the mark at bottom-left, so the attention dot
    /// appears in permanently reserved space and the icon never shifts.
    static let menuBarDotSide: CGFloat = 7
    static let menuBarDotAir: CGFloat = -2
    static let menuBarDotLift: CGFloat = 3
    static func menuBarCanvas(side: CGFloat) -> NSSize {
        NSSize(width: side + menuBarDotAir + menuBarDotSide,
               height: side + menuBarDotLift)
    }

    @MainActor
    static func makeMenuBarImage(
        side: CGFloat = 18,
        heights: [CGFloat] = ReedIcon.defaultHeights
    ) -> NSImage {
        // Render in solid black; isTemplate=true makes macOS use the alpha
        // mask only and apply the current menubar text color.
        let canvas = menuBarCanvas(side: side)
        let renderer = ImageRenderer(
            content: ReedIcon(fill: .black, heights: heights)
                .frame(width: side, height: side)
                .frame(width: canvas.width, height: canvas.height,
                       alignment: .bottomLeading)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        let image: NSImage
        if let rendered = renderer.nsImage {
            image = rendered
        } else {
            image = NSImage(size: canvas)
        }
        image.size = canvas
        image.isTemplate = true
        return image
    }

    /// The idle brand mark with the persistent amber attention dot baked in —
    /// the menubar breadcrumb while `activeError` is set. Baked into the image
    /// (not a SwiftUI overlay) because MenuBarExtra template-flattens its label
    /// content, which strips the overlay's color and clips its offset. This
    /// variant is deliberately NOT a template: the dot must stay amber. The
    /// drawing handler re-runs per appearance, so the bars follow the menubar's
    /// light/dark tint via `labelColor` at draw time.
    static func makeMenuBarErrorImage(side: CGFloat = 18) -> NSImage {
        // Same canvas as every other menubar image (mark bottom-left), so the
        // dot appears in reserved space with zero layout shift.
        let dotSide = menuBarDotSide
        let air = menuBarDotAir
        let lift = menuBarDotLift
        return NSImage(size: menuBarCanvas(side: side), flipped: false) { _ in
            // Bars: same geometry as the SwiftUI mark (5 bars + 4 gaps, with
            // gap = 0.6 × bar width, spanning the full side).
            let barWidth = side / 7.4
            let gap = barWidth * 0.6
            NSColor.labelColor.setFill()
            for (i, height) in ReedIcon.defaultHeights.enumerated() {
                let barHeight = side * height
                let rect = NSRect(
                    x: CGFloat(i) * (barWidth + gap),
                    y: (side - barHeight) / 2,
                    width: barWidth,
                    height: barHeight
                )
                NSBezierPath(
                    roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2
                ).fill()
            }
            // A bare 7 pt amber (#DF8A1E) circle to the mark's upper right —
            // subtle by design; no contrast ring.
            let dotRect = NSRect(
                x: side + air, y: side - dotSide - 1 + lift, width: dotSide, height: dotSide)
            NSColor(srgbRed: 0.875, green: 0.541, blue: 0.118, alpha: 1).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        // No isTemplate: templating would flatten the amber dot to monochrome.
    }
}

#Preview("Brand mark") {
    ReedIcon(fill: .blue)
        .frame(width: 96, height: 96)
        .padding(40)
}

#Preview("App icon") {
    ReedAppIcon()
        .frame(width: 256, height: 256)
}
