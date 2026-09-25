import SwiftUI

/// Hidden debug panel for QA: read the speech model's state, switch the
/// cleanup tier live, and watch the per-dictation blocked-request tally. Kept
/// out of the normal UI, reachable even in release test builds via a defaults
/// flag:  `defaults write com.local.reed reed.debugMenu -bool YES`
enum DebugMenu {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "reed.debugMenu") }
}

struct DebugMenuSection: View {
    @State private var blocked = NetworkGate.shared.activity.blockedCount
    @State private var cleanupTier = LocalCleanup.tier
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DEBUG")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("net this session - blocked \(blocked)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(blocked > 0 ? .orange : .secondary)
            Divider().padding(.vertical, 2)
            Text(asrLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 2)
            Picker("", selection: $cleanupTier) {
                ForEach(LocalCleanupTier.allCases) { tier in
                    Text(tier.label).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: cleanupTier) { _, newValue in LocalCleanup.setTier(newValue) }
            Text("cleanup - \(cleanupLine)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .onReceive(ticker) { _ in blocked = NetworkGate.shared.activity.blockedCount }
    }

    private var asrLine: String {
        let status = ModelStore.isSpeechModelReady ? "loaded" : (ModelStore.isSpeechModelInstalled ? "installed" : "not installed")
        return "speech model - \(ModelStore.SpeechModel.name) (\(ParakeetFlag.variant)): \(status)"
    }

    private var cleanupLine: String {
        guard cleanupTier == .ai else { return cleanupTier.label }
        if #available(macOS 26.0, *) {
            return AICleanup.isAvailable ? "on-device AI ready" : "AI unavailable (\(AICleanup.unavailableReason ?? "?")) → basic"
        }
        return "AI needs macOS 26 → basic"
    }
}
