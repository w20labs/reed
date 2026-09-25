import SwiftUI

/// The dark-glass card shared by the floating toasts (mic warning, Bluetooth
/// nudge).
///
/// Same material as the overlay pill — `.hudWindow` plus a charcoal tint, not
/// a flat black fill — so the toasts, HUD, and menu read as one material
/// rather than a bolted-on system alert. E4 elevation: these float furthest
/// from their backdrop of all the dark-glass surfaces.
struct HUDCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(width: 320, alignment: .leading)
            .background {
                ZStack {
                    VisualEffectView(material: .hudWindow)
                    Color(.sRGB, red: 0.133, green: 0.141, blue: 0.165, opacity: 1).opacity(0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.4), radius: 22, y: 20)
    }
}

extension View {
    func hudCard() -> some View { modifier(HUDCard()) }
}

/// A button on an `HUDCard`. Hand-styled rather than `.bordered` /
/// `.borderedProminent`: those tint themselves from the system appearance, and
/// these cards are dark glass whatever the Mac is set to — the same reason
/// `DeviceMenu` doesn't use a native `Picker`.
struct HUDCardButton: View {
    let title: String
    var prominent = false
    /// Stretches the button to fill whatever width its container offers,
    /// centering the label — for rows where two buttons should split the
    /// card evenly instead of hugging their own text.
    var fillWidth = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ReedFont.ui(12, 500))
                .foregroundStyle(.white.opacity(prominent ? 0.95 : 0.7))
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(fillOpacity))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var fillOpacity: Double {
        let base = prominent ? 0.16 : 0.07
        return isHovering ? base + 0.05 : base
    }
}

/// Headline + detail + dismiss "×", the shape every HUD toast opens with.
struct HUDCardHeader: View {
    let headline: String
    let detail: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WarnGlyph(hard: false, size: 18, fontSize: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(ReedFont.ui(14, 600))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(ReedFont.ui(12))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
    }
}
