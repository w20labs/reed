import SwiftUI

/// Welcome / step 0. No interaction — just sets the stage. The brand mark
/// breathes (subtle scale animation, ~3.6s cycle) per Reed's motion-over-color
/// pattern; the menu-bar mock below the lede shows exactly where Reed lives
/// once onboarding is done, so the user isn't hunting for it afterward.
struct WelcomeStep: View {
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 18)

            ReedAppIcon()
                .frame(width: 64, height: 64)
                .scaleEffect(breathing ? 1.04 : 1.0)
                .opacity(breathing ? 1.0 : 0.94)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                        breathing = true
                    }
                }

            Spacer().frame(height: 24)

            (Text("Type less. ") + Text("Say more.").foregroundColor(Onb.ink2))
                .font(ReedFont.ui(34, 600))
                .tracking(-0.7)
                .multilineTextAlignment(.center)
                .foregroundStyle(Onb.ink)

            Text("Hold a key anywhere on your Mac, speak, release. Clean text lands at your cursor - fast enough to feel like magic.")
                .font(ReedFont.ui(15))
                .foregroundStyle(Onb.slate)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 460)
                .padding(.top, 14)

            menuBarMock
                .padding(.top, 28)
        }
        .frame(maxWidth: .infinity)
    }

    /// A miniature menu bar with Reed's icon ringed and a callout curving up
    /// from the caption — shows where Reed lives instead of just saying so.
    /// Coordinates mirror the HTML design mock (design/hud-design-system.html,
    /// Onboarding · Welcome) byte-for-byte, per the onboarding "mock is the
    /// source of truth" convention.
    private var menuBarMock: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                Capsule().fill(.white.opacity(0.22)).frame(width: 14, height: 8)
                Capsule().fill(.white.opacity(0.22)).frame(width: 14, height: 8)
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Onb.green, lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.3))
                        .frame(width: 16, height: 16)
                    ReedIcon(fill: .white.opacity(0.95))
                        .frame(width: 12, height: 12)
                }
                Text("9:41")
                    .font(ReedFont.mono(11))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(width: 300, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.180, green: 0.180, blue: 0.200),
                            Color(red: 0.137, green: 0.137, blue: 0.153),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
            )
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 6)

            ZStack {
                MenuBarCalloutCurve()
                    .stroke(Onb.green, style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                MenuBarCalloutHead()
                    .fill(Onb.green)
            }
            .frame(width: 300, height: 20)

            Text("Reed lives in your menu bar")
                .font(ReedFont.ui(12))
                .foregroundStyle(Onb.mute)
        }
    }
}

/// The curved connector from the caption up to Reed's menu-bar icon.
/// Control points are tuned in a 300×20 space (matches the mock's viewBox)
/// and scaled to whatever frame it's given.
private struct MenuBarCalloutCurve: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 300
        let sy = rect.height / 20
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

        var path = Path()
        path.move(to: p(150, 18))
        path.addCurve(to: p(238, -4), control1: p(185, 18), control2: p(230, 18))
        return path
    }
}

/// A small filled arrowhead oriented to the callout curve's end tangent —
/// a crisp dart rather than a stroked, round-jointed chevron.
private struct MenuBarCalloutHead: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 300
        let sy = rect.height / 20
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

        let end = p(238, -4)
        let control = p(230, 18)
        let delta = CGPoint(x: end.x - control.x, y: end.y - control.y)
        let len = max((delta.x * delta.x + delta.y * delta.y).squareRoot(), 0.001)
        let dir = CGPoint(x: delta.x / len, y: delta.y / len)
        let perp = CGPoint(x: -dir.y, y: dir.x)

        let headLength: CGFloat = 6.5 * sx
        let headWidth: CGFloat = 5.5 * sx
        let back = CGPoint(x: end.x - dir.x * headLength, y: end.y - dir.y * headLength)
        let corner1 = CGPoint(x: back.x + perp.x * headWidth / 2, y: back.y + perp.y * headWidth / 2)
        let corner2 = CGPoint(x: back.x - perp.x * headWidth / 2, y: back.y - perp.y * headWidth / 2)

        var path = Path()
        path.move(to: corner1)
        path.addLine(to: end)
        path.addLine(to: corner2)
        path.closeSubpath()
        return path
    }
}
