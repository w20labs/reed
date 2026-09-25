import Foundation

/// One continuous progress reading across the model's two very different
/// phases, shared by onboarding's On-device setup step and Settings' download
/// row so the two can never drift apart.
///
/// The problem it solves: `ModelDownloadController.fraction` measures the
/// network download only. The speech model's CoreML load and the Neural Engine
/// specialization that follows it report no progress at all — measured ~59 s
/// on Apple Silicon (Round-1 bench), and observed at 77 s end-to-end for
/// Accurate on 2026-08-12. Both surfaces used to answer that by swapping the
/// bar out for an indeterminate spinner the moment bytes finished, which threw
/// away the one thing the user was reading and told them nothing about when it
/// would end.
///
/// Instead the bar keeps running: the download drives the first
/// `downloadShare` of it, and preparation drives the rest against a time
/// estimate. The estimate is explicitly hedged in the copy ("about"), and the
/// bar is CAPPED below 1.0 — it never claims to be finished before the model
/// has actually loaded, because a bar that hits 100% and keeps going is the
/// same lie as a spinner that never ends.
enum ModelPrep {
    /// How much of the bar the byte download owns. The remainder belongs to
    /// the load; roughly proportional to the two phases' real durations for
    /// Accurate on a warm connection.
    static let downloadShare = 0.75
    /// Bench figure for the CoreML load + ANE specialization.
    static let estimate: TimeInterval = 60
    /// The bar's ceiling while preparing. Reaching exactly 1.0 is reserved for
    /// "the model is loaded", which is signalled by the phase ending, not by
    /// this function.
    static let ceiling = 0.99

    /// True once the bytes are down and the CoreML load has taken over.
    static func isPreparing(downloadFraction: Double) -> Bool { downloadFraction >= 1 }

    /// The single 0…1 value to draw, across both phases.
    static func barFraction(downloadFraction: Double,
                            preparingSince: Date?,
                            now: Date = Date()) -> Double {
        guard isPreparing(downloadFraction: downloadFraction), let since = preparingSince else {
            return downloadShare * max(0, min(1, downloadFraction))
        }
        let elapsed = min(1, max(0, now.timeIntervalSince(since) / estimate))
        // Decelerating, so an over-running load slows down rather than
        // slamming into the ceiling and sitting there.
        let eased = 1 - pow(1 - elapsed, 2)
        return downloadShare + (ceiling - downloadShare) * eased
    }

    /// The right-hand detail: megabytes while downloading, a hedged estimate
    /// while preparing. `nil` means "draw nothing there".
    static func detail(downloadFraction: Double,
                       sizeMB: Int,
                       preparingSince: Date?,
                       now: Date = Date()) -> String? {
        guard isPreparing(downloadFraction: downloadFraction) else {
            let pct = Int(downloadFraction * 100)
            return "\(pct)% · \(Int(downloadFraction * Double(sizeMB))) of \(sizeMB) MB"
        }
        guard let since = preparingSince else { return "about a minute left" }
        let remaining = estimate - now.timeIntervalSince(since)
        // Rounded to 10 s so it reads as the estimate it is instead of
        // ticking like a real countdown, and it never counts to zero — past
        // the estimate it stops guessing.
        guard remaining > 12 else { return "almost there" }
        let rounded = Int((remaining / 10).rounded()) * 10
        return "about \(rounded)s left"
    }
}
