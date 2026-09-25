import SwiftUI

/// One-shot "What's new" sheet shown the first time the user launches a
/// Reed version that has a registered [[WhatsNew]] entry. The window is
/// modal-feeling but not modal — the user can dismiss with the close
/// button or "Got it." Either way the version is marked seen.
///
/// Visual language matches the onboarding flow ([[OnboardingView]]) —
/// Charcoal · Soft Tonal, paper background, monochrome icons, motion only
/// on the chevron of the primary button. Sized small (520×440) because
/// this is a callout, not an experience.
struct WhatsNewView: View {
    let entry: WhatsNewEntry
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 36)
                .padding(.top, 36)

            items
                .padding(.horizontal, 36)
                .padding(.top, 22)

            Spacer(minLength: 0)

            footer
                .padding(.horizontal, 36)
                .padding(.vertical, 18)
                .background(Onb.paper)
                .overlay(alignment: .top) {
                    Rectangle().fill(Onb.line).frame(height: 1)
                }
        }
        .frame(width: 520, height: 460)
        .background(Onb.card)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.tagline)
                .font(ReedFont.mono(10, 600))
                .tracking(1.2)
                .foregroundStyle(Onb.slate)

            Text(entry.title)
                .font(ReedFont.ui(22, 600))
                .foregroundStyle(Onb.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(entry.intro)
                .font(ReedFont.ui(13))
                .foregroundStyle(Onb.slate)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var items: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(entry.items) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.icon)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Onb.ink2)
                        .frame(width: 20, height: 20, alignment: .center)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(ReedFont.ui(13, 600))
                            .foregroundStyle(Onb.ink)
                        Text(item.body)
                            .font(ReedFont.ui(12))
                            .foregroundStyle(Onb.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            if let note = entry.footnote {
                Text(note)
                    .font(ReedFont.ui(11))
                    .foregroundStyle(Onb.slate)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Spacer()
            }

            HStack(spacing: 8) {
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                Button("Got it", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
