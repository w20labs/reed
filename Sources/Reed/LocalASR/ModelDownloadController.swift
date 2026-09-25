import Foundation
import SwiftUI

/// Owns the speech model's download lifecycle (P15, DECIDED 2026-09-02):
/// onboarding's Download button, the launch-time repair when the files went
/// missing, and the progress every surface draws. A singleton, deliberately
/// not view-owned: closing a window must not stop the download.
///
/// The rules it encodes:
/// - One model, no choice. `start()` is the consent for the 461 MB fetch;
///   there is nothing to pick.
/// - The bar covers BOTH phases: the bytes, then the first CoreML compile
///   for this chip (FluidAudio's `.compiling` phase, tens of seconds, no
///   byte progress) — `preparingSince` lets `ModelPrep` keep one bar moving.
/// - Done means loaded, not fetched: `finishSuccess` runs only after
///   `ParakeetClient.prepare` returned, which records the model as proven
///   to load; onboarding's Continue reads that record.
/// - Never a silent fallback: while downloading, dictation surfaces
///   "still downloading — N%" (see `Coordinator.localError`).
@MainActor
final class ModelDownloadController: ObservableObject {
    static let shared = ModelDownloadController()

    enum Phase: Equatable {
        case idle
        case downloading
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var fraction: Double = 0
    /// When the bytes finished and the CoreML compile took over.
    @Published private(set) var preparingSince: Date?

    private var task: Task<Void, Never>?
    /// Identifies the attempt a task belongs to, so a superseded attempt's
    /// outcome never lands on the one that replaced it.
    private var attempt = 0
    private let dlog = Log(category: "modeldownload")

    private init() {}

    var isDownloading: Bool { phase == .downloading }
    var isPreparing: Bool { isDownloading && preparingSince != nil }

    /// One-line status for the dictation HUD's "still downloading" error.
    var hudProgressLine: String? {
        guard isDownloading else { return nil }
        if isPreparing {
            return "The speech model is being prepared for this Mac. Dictation will work in a moment."
        }
        return "The speech model is \(Int(fraction * 100))% downloaded. Dictation will work as soon as it finishes."
    }

    /// The Download button, and the repair path. Idempotent while in flight.
    func start() {
        guard !isDownloading else { return }
        run()
    }

    /// Launch: an install that finished onboarding but whose model files are
    /// missing or corrupt re-downloads on its own, with the same progress
    /// flow as onboarding (P15). Dictation meanwhile waits on the HUD.
    func repairIfNeeded() {
        // Never from a test process: a 461 MB download is not a unit test's
        // business, and CI has no model on purpose (2026-09-03).
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard UserDefaults.standard.bool(forKey: OnboardingState.completedKey),
              !ModelStore.isSpeechModelInstalled,
              !isDownloading else { return }
        dlog.error("speech model missing on disk after setup — downloading it again")
        run()
    }

    func retry() {
        guard case .failed = phase else { return }
        run()
    }

    /// Cancel a download in flight. Nothing is left half-installed: a
    /// cancelled prepare commits no model.
    func cancel() {
        task?.cancel()
        task = nil
        Task { await ParakeetClient.shared.cancelPrepare() }
        settle()
    }

    func dismissFailure() {
        settle()
    }

    private func settle() {
        phase = .idle
        fraction = 0
        preparingSince = nil
    }

    private func run() {
        // `retry()` reaches here with a task already stored; a dropped-but-
        // running task would report its own outcome over the new attempt.
        task?.cancel()
        phase = .downloading
        fraction = 0
        preparingSince = nil
        attempt &+= 1
        let thisAttempt = attempt
        // The controller is a permanent singleton — strong captures are fine.
        task = Task {
            do {
                try await ParakeetClient.shared.prepare { fraction, compiling in
                    Task { @MainActor in ModelDownloadController.shared.report(fraction, compiling: compiling) }
                }
                finishSuccess()
            } catch is CancellationError {
                // Our own cancel() already settled state, and a retry's
                // cancel of THIS attempt must not touch the new one. A
                // cancellation from elsewhere (a mode switch unloading the
                // engine mid-download, review 2026-09-03) must not leave
                // "downloading" on screen forever.
                if thisAttempt == attempt, isDownloading { settle() }
            } catch {
                guard thisAttempt == attempt else { return }
                finishFailure(error)
            }
        }
    }

    private func report(_ value: Double, compiling: Bool) {
        // Progress only while a download is actually running: a late
        // callback from a cancelled download must not resurrect the bar.
        guard isDownloading else { return }
        // Monotonic: FluidAudio restarts its fraction per model file during
        // the compile phase; the bar must never step back.
        fraction = max(fraction, min(value, 1))
        if compiling || value >= 1 {
            fraction = 1
            if preparingSince == nil { preparingSince = Date() }
        }
    }

    private func finishSuccess() {
        guard !Task.isCancelled else { return }
        dlog.info("speech model ready (\(ModelStore.SpeechModel.name))")
        settle()
        // Installed-state is derived from disk + the loaded record, not
        // @Published — tell observers the world changed.
        objectWillChange.send()
        // The Whisper retirement rides every proven load, not only the
        // launch prewarm (review 2026-09-03, P3): a launch that needed the
        // repair used to miss it until the next launch.
        Task.detached(priority: .utility) {
            let removed = ModelStore.removeUnusedWhisperModels()
            if !removed.isEmpty { Log(category: "modeldownload").info("retired unused WhisperKit models: \(removed.joined(separator: ", "))") }
        }
    }

    private func finishFailure(_ error: Error) {
        guard !Task.isCancelled else { return }
        dlog.error("speech model download failed: \(error.localizedDescription)")
        phase = .failed(message: Self.failureMessage(for: error))
        fraction = 0
        preparingSince = nil
    }

    /// Curated failure copy (audit 2026-08-25): every failure used to say
    /// "Check your connection", which sent a user without disk space into an
    /// unfixable retry loop. Static + pure for tests.
    nonisolated static func failureMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileWriteOutOfSpaceError || ns.code == NSFileWriteVolumeReadOnlyError {
            return "Not enough disk space for the speech model. Free up space and try again."
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) {
            return "Not enough disk space for the speech model. Free up space and try again."
        }
        if error is URLError || ns.domain == NSURLErrorDomain {
            return "The download stopped. Check your connection and try again - it resumes from where it left off."
        }
        return "The speech model couldn't be downloaded or loaded. Try again - if it keeps failing, report it from Settings → About (Report an issue)."
    }
}
