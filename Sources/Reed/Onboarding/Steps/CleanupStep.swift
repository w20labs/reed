import AppKit
import SwiftUI

/// File-private mirror of `AICleanup.CleanupAvailability` without the
/// `@available(macOS 26.0, *)` that type carries — see the identical copies in
/// `OnDeviceSetupStep` and `CleanupPane` for why a version-gated type cannot be
/// a stored property on a view that isn't gated.
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

/// Setup's sixth step, after the speech model: one switch deciding whether
/// Reed tidies what you said before it lands (design/hud-design-system.html →
/// "Onboarding · Cleanup — after Speech model · never blocking",
/// DECIDED 2026-08-12).
///
/// Never blocking — `OnboardingState.canAdvance(.cleanup)` is always true.
/// Cleanup is a preference, not a requirement: with Apple Intelligence off, or
/// on macOS < 26, it still runs on the rules pass.
///
/// The Apple Intelligence *check* deliberately does not live here — it runs one
/// step earlier, on `OnDeviceSetupStep`, so the trip to System Settings is
/// spent during the model download instead of after it. By the time this step
/// appears the user is usually back and it reads as available.
struct CleanupStep: View {
    /// Seeded from disk so Back into this step shows the real answer.
    @State private var enabled = LocalCleanup.tier != .off
    /// See `OnDeviceSetupStep.availability` for why this is cached in state
    /// rather than read inline: nothing tells SwiftUI to re-evaluate when
    /// Apple Intelligence changes in a different app.
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
            Text("Clean up as you talk")
                .font(ReedFont.ui(26, 600))
                .tracking(-0.5)
                .foregroundStyle(Onb.ink)
            Text("Reed can drop the \u{201C}um\u{201D}s and fix punctuation before the text lands. It never changes your meaning.")
                .font(ReedFont.ui(14))
                .foregroundStyle(Onb.slate)
                .lineSpacing(2)
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.top, 10)

            switchCard
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 26)

            beforeAfter
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 12)

            footnote
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 16)

            Spacer()
        }
        .onAppear(perform: settleTier)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // Back from System Settings, having turned Apple Intelligence on
            // (or having run Software Update).
            if #available(macOS 26.0, *) { availability = .from(AICleanup.cleanupAvailability) }
        }
    }

    /// Arriving at this step is itself an answer, so it writes a tier the
    /// Settings checkbox can draw.
    ///
    /// `LocalCleanup.tier` falls back to `.basic` when unset, but Settings'
    /// Cleanup checkbox only ever writes `.ai` or `.off` — so before this step
    /// existed, every fresh install sat in a third state no user could choose
    /// and no UI could display: an unchecked-looking box that was not off.
    /// Writing an explicit value on appear is what retires it, and any legacy
    /// `.basic` install that reaches this step is normalized the same way.
    private func settleTier() {
        let stored = UserDefaults.standard.string(forKey: LocalCleanup.tierKey)
        if stored == nil || stored == LocalCleanupTier.basic.rawValue {
            LocalCleanup.setTier(.ai)   // on by default; degrades to basic on its own
            enabled = true
        }
    }

    // MARK: - The switch (the same control as Settings → Cleanup)

    private var switchCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .onChange(of: enabled) { _, newValue in
                    // `.ai` already degrades to `.basic` by itself wherever
                    // Apple Intelligence can't run, so the switch stays a
                    // switch on every macOS.
                    LocalCleanup.setTier(newValue ? .ai : .off)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean up what I say")
                    .font(ReedFont.ui(13.5, 600))
                    .foregroundStyle(Onb.ink)
                Text("Drops filler words, fixes punctuation and capitals. Never changes your meaning.")
                    .font(ReedFont.ui(12))
                    .foregroundStyle(Onb.slate)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Onb.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Onb.hair, lineWidth: 1)
        }
    }

    /// One example, because nobody reads a description of cleanup.
    private var beforeAfter: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("BEFORE")
            Text("so um i think we should ship it on friday i mean if the tests pass")
                .font(ReedFont.ui(13))
                .foregroundStyle(Onb.slate)
                .padding(.top, 3)
            label("AFTER").padding(.top, 10)
            Text("I think we should ship it on Friday, if the tests pass.")
                .font(ReedFont.ui(13))
                .foregroundStyle(Onb.ink)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Onb.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Onb.hair, lineWidth: 1)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(ReedFont.mono(10, 500))
            .tracking(0.8)
            .foregroundStyle(Onb.slate)
    }

    // MARK: - What runs the cleanup

    @ViewBuilder
    private var footnote: some View {
        if #available(macOS 26.0, *) {
            switch availability {
            case .available, .preparing:
                Text("Apple Intelligence is on, so cleanup runs on the on-device model.")
                    .font(ReedFont.ui(12.5))
                    .foregroundStyle(Onb.slate)
            case .notEnabled:
                VStack(alignment: .leading, spacing: 11) {
                    banner("Apple Intelligence is off \u{2014} turn it on and Reed will use it for cleanup",
                           action: "Turn on\u{2026}", perform: AICleanup.openSystemSettings)
                    Text("Cleanup still works without it \u{2014} it just uses the rules pass instead.")
                        .font(ReedFont.ui(12.5))
                        .foregroundStyle(Onb.slate)
                }
            }
        } else {
            // Not "cleanup is broken" — BasicCleanup genuinely cleans filler
            // words and punctuation on every supported macOS. The upgrade buys
            // the sharper on-device model, and saying more than that would be
            // a false claim made to sell an update.
            banner("Cleanup is running on rules. The sharper on-device AI version needs macOS 26 \u{2014} this Mac is on macOS \(Self.osVersion).",
                   action: "Update macOS\u{2026}", perform: Self.openSoftwareUpdate)
        }
    }

    private func banner(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Onb.orange)
            Text(text)
                .font(ReedFont.ui(13, 500))
                .foregroundStyle(Onb.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action, action: perform)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Onb.orangeBg)
        }
    }

    /// "15.4" — major.minor is what a user recognizes as their macOS version.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Deep-link to Software Update, falling back to System Settings itself.
    /// Deliberately NOT on `AICleanup`, which is `@available(macOS 26.0, *)` —
    /// this is only ever needed on the versions that can't see that type.
    static func openSoftwareUpdate() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            let app = URL(fileURLWithPath: "/System/Applications/System Settings.app")
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}
