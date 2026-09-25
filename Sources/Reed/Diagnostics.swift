import Foundation
import Sentry

/// Crash + error reporting, wrapped so Sentry lives in exactly one place. The
/// DSN comes from Info.plist `SentryDSN`; empty = no-op. Nothing is sent until
/// the user turns it on (Settings → Privacy), and no transcript, audio or key
/// is ever attached. Not the same as anonymous: `sendDefaultPii` is off and
/// `beforeSend` clears the event's user, but the crash payload still carries
/// the SDK's hashed device-and-app identifier (`device_app_hash`), and Sentry
/// uses its own URLSession, so `GateURLProtocol` does not cover it.
enum Diagnostics {
    /// Stored as the *disabled* flag. OPT-IN: an ABSENT value means OFF, and
    /// only the Settings → Privacy toggle turns it on; Reed never asks
    /// (2026-09-14). An explicit stored value, either way, is honored.
    static let optOutKey = "reed.crashReportsDisabled"

    /// Every capture/breadcrumb/start path guards on this.
    static var isEnabled: Bool { isEnabled(in: .standard) }

    /// Seam for tests — the opt-in DEFAULT is the policy under test, and it
    /// can only be observed in defaults free of this machine's real choice.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        guard let disabled = defaults.object(forKey: optOutKey) as? Bool else { return false }
        return !disabled
    }

    /// Call once at launch.
    static func start() {
        guard isEnabled, let dsn = dsn else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = isDebug ? "debug" : "production"
            options.sendDefaultPii = false
            options.tracesSampleRate = 0
            // Sentry's URLSession swizzle otherwise auto-captures every
            // 4xx/5xx as its own issue. Reed's remaining requests are the
            // model download, update checks and analytics — a failed one is
            // retried by its own layer or surfaces in the UI, so it is noise
            // as an issue. What Reed does report it reports explicitly,
            // through the `capture` / `captureMessage` / `breadcrumb`
            // wrappers below, each gated on `isEnabled`. HTTP-level
            // breadcrumbs stay on (useful context), just not the
            // noise-as-issues stream.
            options.enableCaptureFailedRequests = false
            // MetricKit lets the OS hand us the .ips of crashes Sentry's own
            // signal handler missed (e.g. Bundle.module fatalError during
            // dispatch_once, which traps the process too fast to flush).
            // Raw payload stays off so we don't risk leaking path strings.
            if #available(macOS 12.0, *) {
                options.enableMetricKit = true
            }
            options.beforeSend = { event in
                event.user = nil
                return event
            }
        }
    }

    /// Toggle from Settings — start or stop reporting immediately.
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(!enabled, forKey: optOutKey)
        if enabled { start() } else { SentrySDK.close() }
    }

    static func breadcrumb(_ message: String, category: String = "app") {
        guard isEnabled else { return }
        let crumb = Breadcrumb(level: .info, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    static func capture(_ error: Error) {
        guard isEnabled else { return }
        SentrySDK.capture(error: error)
    }

    /// Send a plain message (no `Error` value) as a Sentry issue. Used for
    /// signals that aren't exceptions — e.g. "we saw a dictation target app
    /// we don't have a category for yet."
    static func captureMessage(_ message: String) {
        guard isEnabled else { return }
        SentrySDK.capture(message: message)
    }

    /// Whether this build carries a Sentry DSN at all (D3, 2026-09-21). The
    /// repository ships it empty and `build-app.sh` injects it for official
    /// releases, so a build from source reports nowhere. Settings asks this
    /// before offering the crash-report toggle.
    static var isConfigured: Bool { dsn != nil }

    private static var dsn: String? { TelemetryIdentifier.value(forKey: "SentryDSN") }

    private static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
