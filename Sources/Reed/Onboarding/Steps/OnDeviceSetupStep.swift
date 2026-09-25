import AppKit
import SwiftUI

/// The speech-model step (P15, DECIDED 2026-09-02): one card, no choice.
/// The Download button is the consent for the 461 MB fetch; one bar covers
/// the bytes and the first CoreML compile; Continue is gated by
/// `OnboardingState.canAdvance` on `ModelStore.isSpeechModelReady` — proven
/// to load, not merely fetched — so the first dictation is never a cold one.
/// Also (macOS 26+) the Apple Intelligence nudge, paid for while the bytes
/// move.
/// Mirrors `AICleanup.CleanupAvailability` without the `@available(macOS
/// 26.0, *)` that type carries — needed because `AICleanup` itself is
/// version-gated, so it can't be used as a stored-property type on a struct
/// that isn't (the compiler rejects that even inside an `if #available`
/// initializer). `from(_:)` does the one-time conversion at each call site.
private enum CleanupNudge {
    case available, notEnabled, preparing

    @available(macOS 26.0, *)
    static func from(_ availability: AICleanup.CleanupAvailability) -> CleanupNudge {
        switch availability {
        case .available: return .available
        case .notEnabled: return .notEnabled
        case .preparing: return .preparing
        }
    }
}

struct OnDeviceSetupStep: View {
    @ObservedObject private var download = ModelDownloadController.shared
    /// True when the step opened with the model already proven to load —
    /// re-running onboarding on a set-up Mac. Read once: the live state
    /// during this visit comes from the controller.
    @State private var foundOnArrival = ModelStore.isSpeechModelReady
    /// Snapshot of `AICleanup.cleanupAvailability`, cached in state so the
    /// nudge banner can be redrawn. `AICleanup`'s availability check itself
    /// isn't observable — reading it directly meant the banner never updated
    /// after the user changed Apple Intelligence settings and returned to
    /// Reed. Refreshed on `didBecomeActiveNotification` below.
    @State private var availability: CleanupNudge

    init() {
        if #available(macOS 26.0, *) {
            _availability = State(initialValue: .from(AICleanup.cleanupAvailability))
        } else {
            _availability = State(initialValue: .notEnabled)
        }
    }

    private var ready: Bool { ModelStore.isSpeechModelReady && !download.isDownloading }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Download the speech model")
                .font(ReedFont.ui(26, 600))
                .tracking(-0.5)
                .foregroundStyle(Onb.ink)
            Text("Dictation runs entirely on this Mac. One download, then it works offline - Continue unlocks when the model is ready.")
                .font(ReedFont.ui(14))
                .foregroundStyle(Onb.slate)
                .lineSpacing(2)
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.top, 10)

            modelCard
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 26)

            cleanupFootnote
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 18)

            Spacer()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // The user likely just returned from System Settings, either
            // having turned Apple Intelligence on or off.
            if #available(macOS 26.0, *) { availability = .from(AICleanup.cleanupAvailability) }
        }
    }

    // MARK: - The model card: one model, four states

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ModelStore.SpeechModel.name)
                        .font(ReedFont.ui(13.5, 600))
                        .foregroundStyle(Onb.ink)
                    Text(ModelStore.SpeechModel.detail)
                        .font(ReedFont.ui(12))
                        .foregroundStyle(Onb.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Onb.card)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Onb.hair, lineWidth: 1)
            }

            switch download.phase {
            case .downloading:
                progressRows
                    .padding(.top, 12)
            case .failed(let message):
                failedRows(message)
                    .padding(.top, 12)
            case .idle:
                Text(ready
                     ? (foundOnArrival ? "Found on this Mac, nothing to download. Dictation works offline."
                                       : "Installed and loaded. Dictation works offline from here on.")
                     : "Needs a network connection once. Nothing you say is ever uploaded.")
                    .font(ReedFont.ui(12))
                    .foregroundStyle(ready ? Onb.onGreen : Onb.mute)
                    .padding(.top, 10)
            }
        }
    }

    /// The card's right edge: size before the click, a Ready mark after.
    @ViewBuilder private var trailing: some View {
        if ready {
            Label("Ready", systemImage: "checkmark")
                .font(ReedFont.ui(12.5, 600))
                .foregroundStyle(Onb.onGreen)
        } else if download.isDownloading {
            Text("\(ModelStore.SpeechModel.sizeMB) MB")
                .font(ReedFont.mono(12))
                .foregroundStyle(Onb.slate)
        } else {
            Button("Download") { download.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
    }

    /// ONE bar for both phases. `download.fraction` covers the bytes; the
    /// CoreML compile that follows reports no byte progress, so `ModelPrep`
    /// keeps the bar moving on a time estimate, capped below 100% — it never
    /// claims to be done before the model has actually loaded.
    private var progressRows: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let preparing = ModelPrep.isPreparing(downloadFraction: download.fraction)
            let bar = ModelPrep.barFraction(downloadFraction: download.fraction,
                                            preparingSince: download.preparingSince,
                                            now: context.date)
            let detail = ModelPrep.detail(downloadFraction: download.fraction,
                                          sizeMB: ModelStore.SpeechModel.sizeMB,
                                          preparingSince: download.preparingSince,
                                          now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(preparing ? "Preparing for this Mac…" : "Downloading…")
                        .font(ReedFont.ui(12.5, 600))
                        .foregroundStyle(Onb.ink)
                    Spacer(minLength: 0)
                    if let detail {
                        Text(detail)
                            .font(ReedFont.mono(11))
                            .foregroundStyle(Onb.slate)
                            .monospacedDigit()
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Onb.paper2)
                        Capsule().fill(Onb.charcoal)
                            .frame(width: max(8, geo.size.width * bar))
                            .animation(.linear(duration: 0.5), value: bar)
                    }
                }
                .frame(height: 8)
                HStack(alignment: .firstTextBaseline) {
                    Text(preparing
                         ? "The model is being compiled for your chip. Only the first time, up to a minute."
                         : "You can keep going through setup in the meantime. Continue unlocks when the model is ready.")
                        .font(ReedFont.ui(12))
                        .foregroundStyle(Onb.mute)
                    Spacer(minLength: 0)
                    // The compile is not interruptible — Cancel goes with the bytes.
                    if !preparing {
                        Button("Cancel") { download.cancel() }
                            .buttonStyle(.plain)
                            .font(ReedFont.ui(12))
                            .foregroundStyle(Onb.slate)
                            .underline()
                    }
                }
            }
        }
    }

    private func failedRows(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Onb.orange)
            Text(message)
                .font(ReedFont.ui(12.5))
                .foregroundStyle(Onb.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Try again") { download.retry() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - Cleanup availability footnote

    /// The Apple Intelligence check lives HERE rather than on the Cleanup
    /// step that follows (DECIDED 2026-08-12): this is the one stretch of
    /// onboarding with minutes of dead time, so the trip to System Settings
    /// is paid while the model downloads instead of after it.
    ///
    /// macOS 26+: `.notEnabled` gets the amber nudge + System Settings
    /// shortcut. `.preparing` shows nothing, same as `.available` — cleanup
    /// already falls back to Basic meanwhile. macOS < 26 → plain info line.
    @ViewBuilder
    private var cleanupFootnote: some View {
        if #available(macOS 26.0, *) {
            switch availability {
            case .available, .preparing:
                EmptyView()
            case .notEnabled:
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Onb.orange)
                    Text("Apple Intelligence is off. Turn it on while this downloads and Reed will use it for cleanup.")
                        .font(ReedFont.ui(13, 500))
                        .foregroundStyle(Onb.ink)
                    Spacer(minLength: 0)
                    Button("Turn on…", action: AICleanup.openSystemSettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Onb.orangeBg)
                }
            }
        } else {
            Text("On-device AI cleanup needs macOS 26 - filler words and punctuation still get cleaned up, just without it.")
                .font(ReedFont.ui(12.5))
                .foregroundStyle(Onb.slate)
        }
    }
}
