import Foundation
import SwiftUI

/// Lightweight, observable mirror of the bits of Coordinator state the overlay
/// needs to render. Decoupling it from Coordinator avoids a retain cycle
/// between Coordinator → OverlayController → NSHostingView → SwiftUI view →
/// Coordinator.
@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var state: Coordinator.State = .idle
    /// Live mic input level, 0…1, driven by the recorder tap. Flat (~0) when
    /// silent — the meter must tell the truth about what the mic hears.
    @Published var level: Float = 0
    /// Elapsed recording seconds, ticked by the controller while recording.
    @Published var elapsed: Int = 0
    /// Debug per-stage timing line for the Done beat (design rule ⑩), nil unless
    /// `reed.debugTimings` is set.
    @Published var timings: String?
    /// True during the brief success "beat" after a dictation lands, so the
    /// check + "Done" lingers visibly instead of the pill blanking to idle.
    @Published var justFinished = false
    /// Drives the error glyph colour: red for a hard failure, amber otherwise.
    @Published var errorIsHard = false
    /// True while `.warming` on a Bluetooth input. macOS has to switch the
    /// device from A2DP to HFP/SCO before a single frame is audible, so for
    /// 0.5-1.5 s the mic is genuinely deaf — the pill says "Preparing mic…"
    /// with the spinner instead of claiming Listening at a waveform.
    @Published var micIsPreparing = false
    /// True from the moment the panel is ordered in until it is ordered out.
    /// The view renders nothing while false, so no animation (the ring's
    /// endless spin) keeps redrawing inside the hidden panel between
    /// dictations — that redraw cost ~20% CPU idle, plus WindowServer.
    @Published var isOnScreen = false
}
