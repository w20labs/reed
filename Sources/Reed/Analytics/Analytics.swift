import Aptabase
import Foundation

/// Privacy-preserving usage analytics.
///
/// Content is **never** sent — only counts, length *buckets* (ranges, so a length
/// can't fingerprint a phrase), latency, and success/error enums. No transcript
/// text, no audio, no API keys. Aptabase itself sets no persistent user or
/// device identifier: it stamps each event with a random session id that is
/// regenerated after an hour of inactivity. It also auto-collects app version
/// and build, OS name and version, the language code, the Mac's model
/// identifier and a debug flag, so we don't send those (aptabase-swift 0.3.11,
/// `AptabaseClient`/`EnvironmentInfo`).
///
/// Opt-in, default-OFF: nothing is sent unless the user turns it on in
/// Settings → Privacy; Reed never asks. `start()` only initializes the SDK (no
/// network); nothing is sent unless `dictation(...)` runs while enabled, so
/// it's safe to initialize unconditionally.
enum Analytics {
    /// The user's stored choice is the only gate; events remain content-free
    /// by construction (buckets and enums, never text). An absent value means
    /// off, and only the Settings → Privacy toggle writes it (2026-09-14: no
    /// onboarding checkbox, no consent card).
    static var isEnabled: Bool { isEnabled(in: .standard) }

    /// Seam for tests — the policy is about the DEFAULT, which can only be
    /// tested against defaults that don't carry this machine's real choice.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "enableAnalytics") as? Bool ?? false
    }

    /// Whether this build carries an Aptabase app key at all (D3, 2026-09-21).
    /// The repository ships the key empty and `build-app.sh` injects it into the
    /// bundle for official releases only, so a build from source reports
    /// nowhere. Settings asks this before offering the analytics toggle: a
    /// switch that cannot send anything must not look like one that can.
    static var isConfigured: Bool { appKey != nil }

    static var appKey: String? { TelemetryIdentifier.value(forKey: "AptabaseAppKey") }

    /// Initialize Aptabase from the app key in Info.plist. The region is encoded
    /// in the key (`A-EU-…`), so the SDK routes to the right host on its own.
    /// Unconfigured is a no-op twice over: this returns early, and the SDK's own
    /// `enqueueEvent` drops every event while its client is nil.
    static func start() {
        guard let key = appKey else { return }
        Aptabase.shared.initialize(appKey: key)
    }

    /// A single completed/failed dictation, content-free. Nil fields are omitted.
    struct Dictation {
        var ok: Bool
        var errorStage: String?
        var cleanupEnabled: Bool
        var wordCount: Int?
        var charCount: Int?
        var recMs: Int?
        var transcribeMs: Int?
        var cleanupMs: Int?
        var e2eMs: Int?
        var targetAppBundleID: String?
        /// Content-free cleanup counts (P16).
        var cleanupCounts: CleanupCounts?
    }

    /// One-shot event describing the user's FIRST dictation (see
    /// FirstDictation): transport + time-to-audio bucket, nothing else.
    static func firstDictation(transport: String, ttaBucket: String) {
        guard isEnabled else { return }
        Aptabase.shared.trackEvent("first_dictation", with: [
            "transport": transport,
            "tta_bucket": ttaBucket,
        ])
    }

    /// Emit one content-free event per dictation.
    @MainActor
    static func dictation(_ event: Dictation) {
        guard isEnabled else { return }

        let targetApp = appCategory(for: event.targetAppBundleID)
        reportAppCategoryGapIfNeeded(bundleID: event.targetAppBundleID, category: targetApp)

        var props: [String: Any] = [
            "ok": event.ok,
            "cleanup_enabled": event.cleanupEnabled,
            "error_stage": event.errorStage ?? "none",
            "target_app": targetApp,
        ]
        if let words = event.wordCount { props["word_bucket"] = wordBucket(words) }
        if let chars = event.charCount { props["char_bucket"] = charBucket(chars) }
        if let recMs = event.recMs {
            props["rec_ms"] = recMs
            props["rec_bucket"] = latencyBucket(recMs)
        }
        if let transcribeMs = event.transcribeMs {
            props["transcribe_ms"] = transcribeMs
            props["transcribe_bucket"] = latencyBucket(transcribeMs)
        }
        if let cleanupMs = event.cleanupMs {
            props["cleanup_ms"] = cleanupMs
            props["cleanup_bucket"] = latencyBucket(cleanupMs)
        }
        if let e2eMs = event.e2eMs {
            props["e2e_ms"] = e2eMs
            props["e2e_bucket"] = latencyBucket(e2eMs)
        }
        // Content-free cleanup counts (P16): computed on every Mac, sent
        // only here, under the same consent as everything else.
        for (key, value) in event.cleanupCounts?.analyticsProperties ?? [:] { props[key] = value }

        Aptabase.shared.trackEvent("dictation", with: props)
    }

    // MARK: - Target-app taxonomy gaps → Sentry

    /// Bundle IDs already escalated to Sentry this app launch — in-memory
    /// only, so it naturally resets on relaunch.
    private static var reportedAppGaps = Set<String>()

    /// Escalate a real-but-unmapped target app to Sentry, once per bundle ID
    /// per app launch, behind the `dictation_target_app_sentry_report`
    /// flag (default off, and there is no flag service since 2026-09-15: only
    /// a per-machine `reed.flagOverride.*` default turns it on, so this stays
    /// off for users) — actionable, worth the raw ID. `"unknown"`
    /// (no frontmost app readable at all) has no bundle ID to report, so it
    /// isn't escalated.
    @MainActor
    private static func reportAppCategoryGapIfNeeded(bundleID: String?, category: String) {
        guard category == "other", let bundleID else { return }
        guard FeatureFlags.shared.isEnabled("dictation_target_app_sentry_report", default: false) else { return }
        guard !reportedAppGaps.contains(bundleID) else { return }
        reportedAppGaps.insert(bundleID)
        Diagnostics.captureMessage("Unmapped dictation target app: \(bundleID)")
    }

    // MARK: - Buckets (ranges only — never exact lengths)

    static func wordBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case 1...5: return "1-5"
        case 6...15: return "6-15"
        case 16...40: return "16-40"
        case 41...100: return "41-100"
        default: return "100+"
        }
    }

    static func charBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case 1...50: return "1-50"
        case 51...150: return "51-150"
        case 151...400: return "151-400"
        case 401...1000: return "401-1000"
        default: return "1000+"
        }
    }

    /// Buckets a millisecond duration into ranges. Sent *alongside* the raw
    /// `_ms` value (unlike word/char buckets, which replace the raw count) —
    /// the raw number still feeds Aptabase's built-in Median/Min/Max/Sum
    /// aggregation, while the bucket gives a histogram-like breakdown view,
    /// which Aptabase has no native support for (aptabase/aptabase#63).
    static func latencyBucket(_ ms: Int) -> String {
        switch ms {
        case ..<1_000: return "0-1s"
        case 1_000..<5_000: return "1-5s"
        case 5_000..<10_000: return "5-10s"
        case 10_000..<15_000: return "10-15s"
        case 15_000..<30_000: return "15-30s"
        case 30_000..<60_000: return "30-60s"
        case 60_000..<120_000: return "60-120s"
        case 120_000..<300_000: return "120-300s"
        default: return "300s+"
        }
    }

    // MARK: - Target app

    /// Bucket a frontmost-app bundle ID into the fixed `target_app` taxonomy.
    /// See `AppCategory` (shared with formatting-mode auto-detection) for the
    /// bundle-ID table and the `"unknown"` vs `"other"` distinction.
    static func appCategory(for bundleID: String?) -> String {
        AppCategory.category(for: bundleID)
    }
}
