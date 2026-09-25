import SwiftUI

/// The speech model's download, wherever it started — onboarding, or the
/// launch-time repair of a set-up install (P15). With the Transcription
/// tab gone this is the one surface that shows progress and, on failure,
/// the curated message with Try again (review 2026-09-03, P1). The hotkey
/// refuses meanwhile (Coordinator.speechModelRefusal), so a dictation is
/// never recorded and then thrown away. Renders nothing while idle.
struct SpeechModelDownloadNotice: View {
    @ObservedObject private var download = ModelDownloadController.shared

    var body: some View {
        switch download.phase {
        case .downloading:
            MenuNoticeBanner(headline: download.isPreparing
                                ? "Preparing the speech model for this Mac"
                                : "Downloading the speech model · \(Int(download.fraction * 100))%",
                             detail: download.hudProgressLine ?? "",
                             // The compile is not interruptible — Cancel goes with the bytes.
                             actionTitle: download.isPreparing ? nil : "Cancel",
                             action: download.isPreparing ? nil : { download.cancel() })
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        case .failed(let message):
            MenuNoticeBanner(headline: "The speech model didn't download",
                             detail: message,
                             actionTitle: "Try again",
                             action: { download.retry() })
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        case .idle:
            EmptyView()
        }
    }
}
