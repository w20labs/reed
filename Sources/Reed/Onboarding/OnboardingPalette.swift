import SwiftUI

/// Explicit color tokens for the onboarding flow. We match the HTML mock's
/// values byte-for-byte rather than reaching for SwiftUI semantic colors so
/// the rendered window matches the design with no surprises across macOS
/// versions or appearance modes.
///
/// Onboarding shares the Settings color scheme: cool near-white surfaces,
/// near-black ink for text, and Reed emerald (#0B7A50) as the single interactive
/// accent (buttons, selection, progress) — matching SettingsStyle so the app
/// reads as one product. Orange stays only as the "pending" functional accent.
enum Onb {
    static let ink     = Color(red: 0.114, green: 0.114, blue: 0.122)  // #1d1d1f
    static let ink2    = Color(red: 0.180, green: 0.180, blue: 0.188)  // #2e2e30
    static let slate   = Color(red: 0.416, green: 0.416, blue: 0.439)  // #6a6a70
    static let mute    = Color(red: 0.592, green: 0.592, blue: 0.616)  // #97979d
    static let hair    = Color(red: 0.863, green: 0.863, blue: 0.871)  // #dcdcde
    static let line    = Color.black.opacity(0.06)
    static let paper   = Color(red: 0.941, green: 0.929, blue: 0.906)  // #f0ede7 warm greige (footer / insets)
    static let paper2  = Color(red: 0.914, green: 0.898, blue: 0.871)  // #e9e6de
    static let card    = Color.white
    /// Charcoal #26262A — the STRUCTURE accent: sidebar rail, primary Continue
    /// button, current-step highlight. Mirrors SettingsStyle.charcoal.
    static let charcoal = Color(red: 0.149, green: 0.149, blue: 0.165)  // #26262A
    /// #55AF48 — the logo's green, and the only green in the brand (the site
    /// runs on the same value). It is a SHAPE colour: dots, rings, checks,
    /// strokes, fills, progress. It is never a text colour — at 12px it
    /// measures 2.76:1 on white, which is not legible, so green text is ink
    /// or slate and the meaning is carried by the word.
    static let green   = Color(red: 0.333, green: 0.686, blue: 0.282)  // #55AF48
    static let greenBg = Color(red: 0.333, green: 0.686, blue: 0.282).opacity(0.10)
    /// What to draw ON the green: ink, not white. White on #55AF48 is 2.76:1;
    /// ink is 6.10:1 — better than the 3.14:1 the old pine chip managed.
    static let onGreen = Color(red: 0.114, green: 0.114, blue: 0.122)
    static let orange  = Color(red: 0.875, green: 0.541, blue: 0.118)  // #df8a1e — design-system amber
    static let orangeBg = Color(red: 0.875, green: 0.541, blue: 0.118).opacity(0.10)
}

/// The design mock's primary onboarding button (`.obcont`): white 14/600 on
/// charcoal, 8-pt corner radius, 9×22 padding, 55% opacity when disabled.
/// Exists because macOS 26 renders `.borderedProminent` as a CAPSULE — the
/// app drifted to pill-shaped buttons the design never drew. The design file
/// is the source of truth; this style is its Swift rendering.
struct OnbPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ReedFont.ui(14, 600))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Onb.charcoal)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.55)
    }
}

/// In-page actions (Grant access, Open System Settings): compact, bordered,
/// quiet — System Settings' own idiom. The page's one charcoal button is the
/// footer's Continue; an in-page action competing at that weight made the
/// step read heavy (founder review, 2026-08-04).
struct OnbSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ReedFont.ui(13, 500))
            .foregroundStyle(Onb.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Color.black.opacity(0.06) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.14), lineWidth: 1)
            )
            .opacity(isEnabled ? 1.0 : 0.55)
    }
}
