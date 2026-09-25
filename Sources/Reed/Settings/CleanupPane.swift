import AppKit
import SwiftUI

/// Settings › Cleanup — split out of Transcription into its own tab (design:
/// "Settings › Cleanup", 2026-08-08): nested under the speech-model row it
/// read as a sub-option rather than the independent on/off it is, and the old
/// Raw/Basic/AI segmented control asked users to pick between tiers they had
/// no basis to evaluate.
extension SettingsView {
    var cleanupPane: some View {
        SettingsPane(title: "Cleanup", hint: "Tidy up filler words and punctuation before dictation lands.") {
            CardGroup {
                CleanupRow()
            }
        }
    }
}

/// Mirrors `AICleanup.CleanupAvailability` without the `@available(macOS
/// 26.0, *)` that type carries — needed because `AICleanup` itself is
/// version-gated, so it can't be used as a stored-property type on a struct
/// that isn't (same issue as `OnDeviceSetupStep.CleanupNudge`; kept as a
/// separate copy rather than shared since Onboarding and Settings don't
/// otherwise depend on each other).
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

/// The Cleanup on/off control. Checked always cleans up filler words and
/// punctuation, silently upgrading to on-device Apple Intelligence when it's
/// available; unchecked leaves the transcript exactly as spoken. Maps onto
/// the existing off/basic/ai `LocalCleanupTier` engine — checked picks `.ai`
/// (which already degrades to `.basic` automatically when Apple Intelligence
/// can't run), unchecked picks `.off` — so the pipeline and the debug menu's
/// tier A/B override are untouched.
struct CleanupRow: View {
    @State private var enabled = LocalCleanup.tier != .off
    /// Snapshot of `AICleanup.cleanupAvailability`, cached in state so
    /// `aiNote` can be redrawn — see `OnDeviceSetupStep.availability` for why
    /// a direct read doesn't update: nothing tells SwiftUI to re-evaluate
    /// this view when Apple Intelligence changes in a different app.
    /// Refreshed on `didBecomeActiveNotification` below.
    @State private var availability: CleanupNudge

    init() {
        if #available(macOS 26.0, *) {
            _availability = State(initialValue: .from(AICleanup.cleanupAvailability))
        } else {
            _availability = State(initialValue: .notEnabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneRow(icon: "sparkles", title: "Cleanup", subtitle: caption) {
                Toggle("", isOn: $enabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .onChange(of: enabled) { _, newValue in
                        LocalCleanup.setTier(newValue ? .ai : .off)
                    }
            }
            aiNote
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // The user likely just returned from System Settings, either
            // having turned Apple Intelligence on or off.
            if #available(macOS 26.0, *) { availability = .from(AICleanup.cleanupAvailability) }
        }
    }

    // Same description whether checked or not (feedback 2026-08-08): what
    // Cleanup DOES only matters while it's on, so the caption always
    // describes the checked behavior rather than flipping to "untouched"
    // when off — the checkbox itself already says that.
    private let caption = "Punctuation and filler-word fixes - never changes meaning. "
        + "Uses on-device Apple Intelligence automatically when it's on."

    /// Same nudge as onboarding's On-device setup step
    /// (`OnDeviceSetupStep.cleanupFootnote`): macOS 26+ with Apple
    /// Intelligence off gets an amber banner + System Settings shortcut.
    /// `.preparing` (on, but the on-device model is still downloading —
    /// disabling has no download step, which is why turning Apple
    /// Intelligence off updated instantly but turning it on didn't) shows
    /// nothing, same as `.available` — a "getting ready" message was more
    /// noise than it was worth (feedback 2026-08-08); cleanup already falls
    /// back to Basic meanwhile. Older macOS gets a plain info line since
    /// there's nothing to turn on.
    @ViewBuilder
    private var aiNote: some View {
        if enabled {
            if #available(macOS 26.0, *) {
                switch availability {
                case .available, .preparing:
                    EmptyView()
                case .notEnabled:
                    HStack(spacing: SettingsSpace.sm) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SettingsStyle.amber)
                        Text("Apple Intelligence gives better cleanup - it's off right now")
                            .font(ReedFont.ui(13, 500))
                        Spacer(minLength: 0)
                        Button("Turn on…", action: AICleanup.openSystemSettings)
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.horizontal, SettingsSpace.md)
                    .padding(.vertical, SettingsSpace.sm)
                    .background(SettingsStyle.amber.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.nestedRadius))
                    .padding(.horizontal, SettingsSpace.lg)
                    .padding(.bottom, SettingsSpace.md)
                }
            } else {
                Text("On-device AI cleanup needs macOS 26 - filler words and punctuation still get cleaned up, just without it.")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SettingsSpace.lg)
                    .padding(.bottom, SettingsSpace.md)
            }
        }
    }
}
