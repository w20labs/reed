import SwiftUI

/// A small styled keycap used in the Done step's "Try it" callout. Renders
/// the symbol with the same monospace + double-bottom-border look as macOS's
/// own help windows, so the user gets a tactile preview of the hotkey.
struct KeycapView: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(ReedFont.mono(13, 500))
            .foregroundStyle(Onb.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Onb.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Onb.hair, lineWidth: 1)
                    }
                    .overlay(alignment: .bottom) {
                        // Subtle "key has depth" detail — the bottom edge is
                        // a hair darker than the rest of the border.
                        Rectangle()
                            .fill(Onb.hair.opacity(0.7))
                            .frame(height: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
    }
}
