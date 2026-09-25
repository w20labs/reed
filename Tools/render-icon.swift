#!/usr/bin/env swift
// Renders Reed's app icon at 1024×1024 as a PNG.
// Run: swift Tools/render-icon.swift <output.png>
//
// Kept Core-Graphics-based (rather than SwiftUI + ImageRenderer) so the
// script runs against the system Swift without needing to compile the
// Reed module. The shape mirrors Sources/Reed/Branding/ReedIcon.swift.

import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "Reed.png"
let side: CGFloat = 1024

// Opaque context (no alpha channel) — full-bleed icon, and the iOS App Store
// rejects icons with transparency.
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(side),
    height: Int(side),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

// Charcoal gradient background (Charcoal · Soft Tonal — no accent color):
// graphite #45454B → #29292D, top-left to bottom-right.
let bgColors: [CGColor] = [
    CGColor(srgbRed: 0.271, green: 0.271, blue: 0.294, alpha: 1.0),
    CGColor(srgbRed: 0.161, green: 0.161, blue: 0.176, alpha: 1.0),
]
guard let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: bgColors as CFArray,
    locations: [0.0, 1.0]
) else {
    fputs("Failed to create gradient\n", stderr)
    exit(1)
}
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: side),
    end: CGPoint(x: side, y: 0),
    options: []
)

// White waveform bars: 5 capsules, heights mirror ReedIcon.heights.
let heights: [CGFloat] = [0.50, 0.78, 1.00, 0.78, 0.50]
// The inner glyph occupies 1024 - 2×230 = 564 pt on BOTH axes — a square box,
// so the waveform is as tall as it is wide. Matches ReedAppIcon's padding.
let innerW: CGFloat = side - 2 * 230
let innerH: CGFloat = side - 2 * 230
let originX: CGFloat = (side - innerW) / 2
let centerY: CGFloat = side / 2

// 5W + 4 × 0.6W = innerW  →  W = innerW / 7.4
let barWidth: CGFloat = innerW / 7.4
let gap: CGFloat = barWidth * 0.6

// Soft-tonal bars (#E8E8EC) — the Charcoal · Soft Tonal pairing.
ctx.setFillColor(CGColor(srgbRed: 0.910, green: 0.910, blue: 0.925, alpha: 1.0))
for (i, height) in heights.enumerated() {
    let x = originX + CGFloat(i) * (barWidth + gap)
    let barHeight = innerH * height
    let y = centerY - barHeight / 2
    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
    let corner = barWidth / 2
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: corner,
        cornerHeight: corner,
        transform: nil
    )
    ctx.addPath(path)
    ctx.fillPath()
}

guard let cgImage = ctx.makeImage() else {
    fputs("Failed to create CGImage\n", stderr)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath) (\(pngData.count) bytes)")
