import AppKit
import Foundation

/// Support for the on-device pipeline, split from Coordinator+Local.swift
/// (file_length): the recognizer call and the per-dictation analytics event.
extension Coordinator {
    /// The one engine call: Parakeet, the one model (P15). Test seam:
    /// replaces the engine call (never the post-processing), so the
    /// segment/cleanup contract above it is unit-testable without models.
    static var transcribeOverride: ((Data) async throws -> String)?

    static func transcribe(wav: Data) async throws -> String {
        let raw: String
        if let override = transcribeOverride {
            raw = try await override(wav)
        } else {
            // The one engine (P15, DECIDED 2026-09-02). No fallback engine:
            // a Parakeet failure is a visible error with Try again, never a
            // quiet engine swap — and a dictation that starts while the
            // model loads waits on the preparing HUD (loadModelIfCold)
            // rather than running on a model the user did not choose.
            // prepare() inside transcribe is a no-op once loaded, and
            // coalesced with any load in flight.
            raw = try await ParakeetClient.shared.transcribe(wav: wav)
        }
        // Engine-level artifact: literal "<unk>" markers are never text
        // (field 2026-08-19 — five of them typed into a document).
        return SilenceArtifact.strippingUnknownTokens(raw)
    }
}
