import SwiftUI

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel

    // Dark-glass content colours — white on the HUD material, legible over any
    // desktop. (Not `.primary`, which would flip to black on a light background.)
    private let content = Color.white.opacity(0.94)
    private let secondary = Color.white.opacity(0.5)

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(height: 24)

            if !label.isEmpty {
                Text(label)
                    .font(ReedFont.ui(13.5, 500))
                    // Notices are deliberately quiet: secondary text, no glyph —
                    // "Nothing to write" must not read like a result or an error.
                    .foregroundStyle(isNotice ? secondary : content)
                    .lineLimit(1)
                    .fixedSize()
            }

            // Debug per-stage timings in the Done beat (design rule ⑩).
            if showsRingCheck, let timings = viewModel.timings {
                Text(timings)
                    .font(ReedFont.mono(10))
                    .foregroundStyle(secondary)
                    .fixedSize()
            }
            if isListening {
                Text(timeString)
                    .font(ReedFont.mono(12))
                    .foregroundStyle(secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
            // `.hudWindow` alone reads medium-grey; a charcoal tint over it
            // darkens the glass to the Figma pill (rgba(34,36,42,~0.6)).
            ZStack {
                VisualEffectView(material: .hudWindow)
                Color(.sRGB, red: 0.133, green: 0.141, blue: 0.165, opacity: 1).opacity(0.62)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.34), radius: 12, y: 8)
        // Hug the content into a compact pill, then centre it in the panel.
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: viewModel.state)
    }

    private var isListening: Bool {
        // Bluetooth warm-up is deliberately NOT "listening": the waveform and
        // the timer both assert live input, and during the SCO handshake there
        // isn't any. It reads as preparation until the first audible frame.
        guard !viewModel.micIsPreparing else { return false }
        switch viewModel.state {
        case .warming, .recording: return true
        default: return false
        }
    }

    /// Bluetooth warm-up: spinner + "Preparing mic…", no wave, no timer.
    private var isPreparingMic: Bool {
        if case .warming = viewModel.state { return viewModel.micIsPreparing }
        return false
    }

    private var isError: Bool {
        if case .error = viewModel.state { return true }
        return false
    }

    private var isNotice: Bool {
        if case .notice = viewModel.state { return true }
        return false
    }

    /// The ring/check glyph spans transcribe → inject → the lingering Done as a
    /// single view (stable identity) so the ring morphs into the check.
    private var showsRingCheck: Bool {
        switch viewModel.state {
        case .preparingModel, .transcribing, .injecting: return true
        case .idle: return viewModel.justFinished
        default: return false
        }
    }

    private var ringDone: Bool {
        switch viewModel.state {
        case .injecting: return true
        case .idle: return viewModel.justFinished
        default: return false
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if isPreparingMic {
            // Same spinner as the other "wait for a prerequisite" state
            // (Preparing speech model…) — a waveform here would claim the mic
            // is hearing something when it physically cannot.
            RingCheck(done: false, color: Color.white.opacity(0.9))
        } else if isListening {
            // Scrolling waveform driven by the real mic level.
            LevelBars(level: CGFloat(viewModel.level), color: content)
        } else if isError {
            // Amber for actionable, red for a hard failure — the only colour the
            // otherwise-monochrome HUD uses.
            WarnGlyph(hard: viewModel.errorIsHard)
        } else if showsRingCheck {
            // Processing → Done as one continuous morph (writing → done). The
            // ring/check strokes at white 0.9 (the design's --stroke token),
            // slightly softer than the text's content white.
            RingCheck(done: ringDone, color: Color.white.opacity(0.9))
        } else {
            EmptyView()
        }
    }

    #if DEBUG
    /// The pill's copy for a given view-model state. The mapping is the design
    /// contract; rendering it needs a SwiftUI host, so tests target this.
    static func labelForTesting(_ viewModel: OverlayViewModel) -> String {
        OverlayView(viewModel: viewModel).label
    }
    #endif

    var label: String {
        switch viewModel.state {
        // The middle (transcribe + cleanup) step carries no word — sub-second, so
        // a label just flickers; the spinner says enough. "Pasting…" is
        // dropped too: injection is one frame; the check says everything.
        case .warming where viewModel.micIsPreparing: return "Preparing mic…"
        case .warming, .recording: return "Listening"
        // The one processing state that DOES carry a word — a cold model load
        // can run tens of seconds and must read as preparation, not a hang.
        case .preparingModel: return "Preparing speech model…"
        case .transcribing: return ""
        case .injecting: return "Done"
        case .error(let message): return message
        case .notice(let message): return message
        case .idle: return viewModel.justFinished ? "Done" : ""
        }
    }

    private var timeString: String {
        let seconds = max(0, viewModel.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The dark HUD material (Apple's `.hudWindow`), blurring the desktop behind the
/// panel — the same glass used by system HUDs. Reads cleanly on any background.
/// Not private: MicWarningController's toast shares this same material.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        // Force dark: `.hudWindow` otherwise follows the system appearance and
        // renders light in Light mode, washing out the white content. The HUD is
        // always dark glass regardless of the user's Light/Dark setting.
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// A scrolling waveform: a rolling history of the mic level, each bar a recent
/// sample so the shape moves as you speak. Center-anchored; a thin flat line
/// when silent.
private struct LevelBars: View {
    let level: CGFloat
    let color: Color
    private static let barCount = 7
    @State private var samples: [CGFloat] = Array(repeating: 0, count: barCount)

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(samples.indices, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: 2.5, height: barHeight(samples[i]))
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.09), value: samples)
        .onChange(of: level) { _, newLevel in
            var next = samples
            next.removeFirst()
            next.append(newLevel)
            samples = next
        }
    }

    private func barHeight(_ sample: CGFloat) -> CGFloat {
        let minH: CGFloat = 5
        let maxH: CGFloat = 22
        // No render-side gain: the recorder's dB curve already normalizes to
        // 0…1, and extra gain here saturates the bars at max on hot mics.
        return minH + (maxH - minH) * min(1, sample)
    }
}

/// The processing ring that morphs into the Done check: a rotating arc while
/// `done` is false; when it flips true the arc completes into a full ring and
/// the check draws inside it — one continuous gesture, not a swap.
private struct RingCheck: View {
    let done: Bool
    let color: Color
    @State private var spin = 0.0

    var body: some View {
        ZStack {
            // Ring: spinning arc while processing; completes into a full circle
            // when done. (A full circle rotating reads as static, so the spin
            // can keep running — no snap.)
            Circle()
                .trim(from: 0, to: done ? 1.0 : 0.746)
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(spin))
                .frame(width: 18, height: 18)
                .animation(.easeOut(duration: 0.18), value: done)

            // Check: grows in at the centre (scale + fade), sized to sit inside
            // the ring with margin so it never touches the stroke. Deliberately
            // on the SAME 0.18 easeOut beat as the ring completion and the
            // pill's width change — a delayed, overshooting spring made the
            // check appear beside its final spot mid-slide and snap into place.
            CheckMark()
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 10, height: 10)
                .scaleEffect(done ? 1 : 0.55)
                .opacity(done ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: done)
        }
        .frame(width: 20, height: 20)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                spin = 360
            }
        }
    }
}

/// A centred check glyph with even margins inside its frame, so it sits
/// comfortably within the ring rather than spanning edge-to-edge.
private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width, height = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + width * 0.12, y: rect.minY + height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.40, y: rect.minY + height * 0.80))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.88, y: rect.minY + height * 0.24))
        return path
    }
}

/// The error accent glyph — amber for actionable, red for a hard failure.
/// Not private: MicWarningController's toast shares this same glyph (at its
/// larger 18/12 spec size; the HUD's default is 16/11).
struct WarnGlyph: View {
    let hard: Bool
    var size: CGFloat = 16
    var fontSize: CGFloat = 11
    private var accent: Color {
        hard ? Color(red: 0.898, green: 0.329, blue: 0.290)   // red
             : Color(red: 0.937, green: 0.635, blue: 0.208)   // amber
    }

    var body: some View {
        Text("!")
            .font(.system(size: fontSize, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(accent))
    }
}
