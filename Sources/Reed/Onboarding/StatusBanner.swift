import SwiftUI

/// Status banner for a required permission step: orange + topical icon
/// when the user hasn't granted it, green + checkmark when they have.
/// Replaces the older StatusCard pattern with a simpler shape — just the
/// banner. `AccessibilityStep` is its one caller today; the Microphone step
/// draws the same state inside its own card, with the mic picker.
///
/// The optional Cleanup step deliberately does NOT use this; it gets its
/// own paper-tinted card that doesn't carry orange "needs you" pressure.
struct StatusBanner: View {
    let granted: Bool
    let pendingIcon: String      // SF Symbol name for the orange state
    let doneText: String
    let pendingText: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : pendingIcon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(granted ? Onb.green : Onb.orange)
                .frame(width: 26, height: 26)
            Text(granted ? doneText : pendingText)
                .font(ReedFont.ui(14, 500))
                .foregroundStyle(Onb.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(granted ? Onb.greenBg : Onb.orangeBg)
        }
    }
}
