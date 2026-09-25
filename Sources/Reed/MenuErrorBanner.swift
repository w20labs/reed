import SwiftUI

/// The persistent, actionable error surface pinned at the top of the menu —
/// where the user reads the failure (curated headline + plain cause), acts on
/// it (Open Settings), and can expand the raw detail. Amber for the
/// common actionable case; red only for a hard failure. Split out of
/// MenuView.swift to keep that file under the swiftlint file-length cap.
struct ErrorBanner: View {
    let error: DictationError
    let onAction: () -> Void
    let onDismiss: () -> Void
    /// "Report this" — opens the GitHub bug form at the failure moment (P10);
    /// Settings › About stays the calm secondary route.
    var onReport: (() -> Void)?

    @State private var showDetails = false

    private var accent: Color { error.severity == .hard ? SettingsStyle.red : SettingsStyle.amber }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: error.severity == .hard
                    ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                Text(error.headline)
                    .font(ReedFont.ui(13, 600))
                    .foregroundStyle(.primary)
                    // Wrap, never truncate: the HStack otherwise compresses the
                    // headline to one ellipsized line at the menu's 280 width.
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Text(error.detail)
                .font(ReedFont.ui(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let title = error.actionTitle {
                    Button(title, action: onAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(accent)
                }
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
                if let onReport {
                    Button("Report this", action: onReport)
                        .buttonStyle(.plain)
                        .font(ReedFont.ui(11, 500))
                        .foregroundStyle(.primary)
                        .underline()
                }
                // Raw-error expander is a diagnosis aid, not product UI (it's
                // not in the design): debug builds only.
                if DebugMenu.isEnabled {
                    Button(showDetails ? "Hide details" : "Details") {
                        withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(ReedFont.ui(11))
                    .foregroundStyle(.tertiary)
                }
            }

            if DebugMenu.isEnabled, showDetails {
                Text(error.raw)
                    .font(ReedFont.mono(10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary.opacity(0.5))
                    }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.28), lineWidth: 1)
        }
    }
}
