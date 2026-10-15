import AppKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// On-device transcript cleanup via Apple's Foundation Models (macOS 26+). No
/// download, no dependency, no network — the system model runs on the Neural
/// Engine. `.greedy` sampling keeps it deterministic, which (with a strict
/// fidelity-preserving prompt) minimizes the risk of a small model altering what
/// the user actually said. Returns nil when the model is unavailable or errors,
/// so `LocalCleanup` falls back to the Basic rules tier.
@available(macOS 26.0, *)
enum AICleanup {
    /// True when the system model is ready (device eligible + Apple Intelligence
    /// enabled + model downloaded).
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// A short human-readable reason the AI tier is off, or nil if available.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason): return "\(reason)"
        @unknown default: return "unavailable"
        }
    }

    /// Coarser than `unavailableReason` — the three buckets the nudge banner
    /// actually needs copy for. Collapsing "not enabled" and "still
    /// downloading" into one "it's off" message (the original nudge copy)
    /// is what produced the 2026-08-08 report: a user who'd just flipped
    /// Apple Intelligence on in System Settings saw the same "off right now"
    /// text as before, because the on-device model can take a few minutes to
    /// download after the toggle — `.unavailable(.modelNotReady)`, not
    /// `.appleIntelligenceNotEnabled`. Turning it off DID update the banner
    /// promptly because that transition has no download step.
    enum CleanupAvailability {
        case available
        /// The user hasn't turned Apple Intelligence on (or the device can't
        /// run it at all) — the "Turn on…" shortcut is the right next step.
        case notEnabled
        /// Apple Intelligence is on; the on-device model is still
        /// downloading/preparing. Nothing to click — just wait.
        case preparing
    }

    static var cleanupAvailability: CleanupAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.modelNotReady): return .preparing
        case .unavailable: return .notEnabled
        @unknown default: return .notEnabled
        }
    }

    /// `repair: true` selects the repair prompt — callers pass it only when a
    /// structural detector has confirmed disfluency (see repairInstructions).
    /// The reply carries its own failure class: nothing about THIS call is
    /// kept in shared state for a concurrent call to overwrite or consume
    /// (review 2026-09-05, P2).
    static func clean(_ text: String, repair: Bool = false) async -> LocalCleanup.ModelReply {
        guard isAvailable else { return .failed("unavailable") }
        let prompt = repair ? repairInstructions : instructions
        // The v2 protocol: input delimited as data, contract restated after it
        // (the "sandwich") — both matter for the small on-device model.
        let wrapped = "<transcript>\n\(text)\n</transcript>\n\n"
            + "Return only the result from inside the <transcript>, with no preamble."
        // Take the prewarmed session if one is ready — a fresh session pays
        // instruction prefill on `respond`, and the measured cleanup floor
        // (~1.2 s even on 39-char input, 2026-08-14) suggests that cost is
        // paid per call, not per model load. A session is single-use: its
        // transcript accumulates, and one dictation must never prime the next
        // (same rule as ParakeetClient's fresh decoder state).
        let pooled = await CleanupSessionStore.shared.take(instructions: prompt)
        let session = pooled ?? LanguageModelSession(instructions: { prompt })
        defer {
            Task { await CleanupSessionStore.shared.refill(instructions: prompt) }
        }
        let first = await respond(session: session, to: wrapped, pooled: pooled != nil, chars: text.count)
        // A wedged session must not cost the cleanup: one retry on a fresh
        // session before the caller falls back to rules (2026-08-29). The
        // decision reads THIS call's reply, never a shared slot.
        guard first.timedOut else { return first }
        log.notice("cleanup model: retrying once on a fresh session")
        return await respond(session: LanguageModelSession(instructions: { prompt }), to: wrapped,
                             pooled: false, chars: text.count, isRetry: true)
    }

    /// Keep-warm tickles currently inside the model (Coordinator+KeepWarm);
    /// logged with a timeout so a wedged tickle can be told from a wedged
    /// runtime.
    @MainActor static var ticklesInFlight = 0

    /// Kick the system model's asset load ahead of time (called at recording
    /// start — the user speaks for seconds anyway, so the first AI call after
    /// idle no longer pays the ~1.4 s cold start). Cheap no-op when warm.
    /// Warms both cleanup prompts — which one a dictation needs isn't known
    /// until its transcript exists.
    static func prewarm() {
        guard isAvailable else { return }
        Task {
            await CleanupSessionStore.shared.refill(instructions: instructions)
            await CleanupSessionStore.shared.refill(instructions: repairInstructions)
        }
    }

    /// The smallest call that keeps the system model hot (lever 6,
    /// docs/bench/idle_penalty.txt): the model goes cold after ~5 s without
    /// a call and charges ~870 ms on the next one — on the stage that is
    /// already the wait. A one-token answer every few seconds of the hold
    /// costs GPU time the user never waits for. It runs on a session from
    /// the cleanup pool, with the cleanup instructions: a throwaway session
    /// with other instructions kept the model warm but left cleanup paying
    /// instruction prefill again (940 ms vs the 610 ms floor,
    /// idle_penalty2.txt). `prewarm()` alone does not do this: a prewarmed
    /// session is loaded, not hot.
    static func tickle() async {
        guard isAvailable else { return }
        let session = await CleanupSessionStore.shared.take(instructions: instructions)
            ?? LanguageModelSession(instructions: { instructions })
        await MainActor.run { ticklesInFlight += 1 }
        defer {
            Task { @MainActor in ticklesInFlight -= 1 }
            Task { await CleanupSessionStore.shared.refill(instructions: instructions) }
        }
        var options = GenerationOptions(sampling: .greedy)
        options.maximumResponseTokens = 1
        _ = try? await withDeadline(timeout) {
            (try? await session.respond(to: "<transcript>\nok\n</transcript>", options: options).content) ?? ""
        }
    }

    /// Hard cap on a single on-device generation. The model normally answers in
    /// 1–3s (first load / slower Macs up to ~5–7s); if it stalls beyond this we
    /// must not leave the dictation HUD spinning — so we time out (via
    /// `withDeadline`) and let the caller fall back to the Basic rules tier. The
    /// fallback is graceful, so a rare false timeout just yields rules-based
    /// cleanup instead of AI.
    /// Now the ceiling of CleanupStats' adaptive deadline; kept as the
    /// documented worst case.
    private static let timeout: TimeInterval = CleanupStats.ceilingDeadline

    private static func respond(session: LanguageModelSession, to text: String,
                                pooled: Bool = false, chars: Int = 0, isRetry: Bool = false) async -> LocalCleanup.ModelReply {
        let options = GenerationOptions(sampling: .greedy)
        // Deadline: adaptive to this Mac's recent calls (CleanupStats), so a
        // stalled call costs ~2.5 s here instead of 8; the caller unblocks
        // even if the runtime never answers.
        let deadline = await CleanupStats.shared.adaptiveDeadline
        let start = Date()
        var failure: String?
        let raw: String?
        do {
            raw = try await withDeadline(deadline) {
                try await session.respond(to: text, options: options).content
            }
        } catch is TimeoutError {
            raw = nil
            failure = String(format: "timeout %.1fs", deadline)
        } catch {
            raw = nil
            failure = "error"
        }
        let elapsed = Date().timeIntervalSince(start)
        if let failure {
            let tickles = await MainActor.run { ticklesInFlight }
            log.error("cleanup model call failed: \(failure) after \(String(format: "%.1f", elapsed))s (availability=\(cleanupAvailability), pooled=\(pooled), ticklesInFlight=\(tickles), chars=\(chars), retry=\(isRetry))")
            await CleanupStats.shared.recordFailure(timedOut: failure.hasPrefix("timeout"))
            return .failed(failure + (isRetry ? " ×2" : ""))
        }
        guard let raw, !raw.isEmpty else {
            await CleanupStats.shared.recordFailure(timedOut: false)
            return .failed("empty")
        }
        await CleanupStats.shared.record(duration: elapsed)
        // The on-device model often ignores "return only the cleaned text" and
        // wraps its answer in a chatty preamble/delimiters — strip that here.
        let cleaned = CleanupSanitizer.strip(raw)
        return cleaned.isEmpty ? .failed("empty") : .text(cleaned)
    }
}

/// Holds at most one prewarmed, never-used session per instruction set (the
/// generic cleaner and the repair prompt). `take` hands one out and empties
/// its slot; `refill` builds and prewarms the next one off the dictation's
/// critical path (at recording start, and again right after each use).
@available(macOS 26.0, *)
private actor CleanupSessionStore {
    static let shared = CleanupSessionStore()
    /// Up to `depth` prewarmed sessions per instruction set — sentence-level
    /// cleanup (2026-08-19) takes one per chunk, so a two-sentence dictation
    /// shouldn't pay instruction prefill on its second sentence.
    private static let depth = 2
    private var warm: [String: [LanguageModelSession]] = [:]

    func take(instructions: String) -> LanguageModelSession? {
        warm[instructions, default: []].popLast()
    }

    func refill(instructions: String) {
        while warm[instructions, default: []].count < Self.depth {
            let session = LanguageModelSession(instructions: { instructions })
            session.prewarm()
            warm[instructions, default: []].append(session)
        }
    }
}

#else

/// Stub for SDKs without the FoundationModels framework (pre-26 toolchains,
/// e.g. CI runners). Same API surface; always unavailable, so `LocalCleanup`
/// falls back to the Basic rules tier exactly as it does at runtime on
/// ineligible machines.
@available(macOS 26.0, *)
enum AICleanup {
    enum CleanupAvailability { case available, notEnabled, preparing }

    static var isAvailable: Bool { false }
    static var unavailableReason: String? { "FoundationModels not in this SDK" }
    static var cleanupAvailability: CleanupAvailability { .notEnabled }
    static func clean(_ text: String, repair: Bool = false) async -> LocalCleanup.ModelReply { .failed("unavailable") }
    static func prewarm() {}
    static func tickle() async {}
    @MainActor static var ticklesInFlight = 0
}

#endif

@available(macOS 26.0, *)
extension AICleanup {
    /// Deep-link to the Apple Intelligence pane (its Siri-extension id is the
    /// best-known stable handle); fall back to just opening System Settings.
    /// Shared by onboarding's On-device setup step and the Cleanup settings
    /// tab so both "Turn on…" buttons behave identically.
    static func openSystemSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            let app = URL(fileURLWithPath: "/System/Applications/System Settings.app")
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}
