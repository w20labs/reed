import SwiftUI

/// Reed's type ramp — the macOS **system font**: SF Pro for UI, SF Mono for
/// shortcut / badge / numeric glyphs. Used app-wide (HUD, menu, onboarding,
/// Settings) so type matches the native controls everywhere and stays crisp at
/// any size. Weight is a CSS-style numeric (400 regular … 700 bold).
///
/// (Was Geist; switched to the system font 2026-07. The Geist TTFs are still
/// bundled but unused — a later cleanup can drop them from Resources/Fonts +
/// Info.plist's ATSApplicationFontsPath if we never bring Geist back.)
enum ReedFont {
    /// UI text — SF Pro.
    static func ui(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        .system(size: size, weight: swiftWeight(weight))
    }

    /// Shortcut / badge / numeric glyphs — SF Mono.
    static func mono(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        .system(size: size, weight: swiftWeight(weight), design: .monospaced)
    }

    private static func swiftWeight(_ weight: CGFloat) -> Font.Weight {
        switch weight {
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }
}
