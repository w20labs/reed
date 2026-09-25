import Foundation

/// Whisper confidently hallucinates short pleasantries ("You", "Thank you.")
/// from near-silent audio that clears the −42 dB pre-ASR gate — a breath or
/// a click can spike the peak while carrying no speech. Separately, the
/// model also reproduces its own literal non-speech tags verbatim
/// ("[BLANK_AUDIO]", "[Music]"), learned from caption-style training data.
/// A transcript counts as an artifact only when BOTH hold: it matches a
/// known hallucination or marker, and the recording's RMS sits below
/// plausible speech.
///
/// Trade-off, accepted deliberately: a whisper-quiet lone "thank you" from
/// across the room gets the "Nothing to write" notice and re-records in a
/// second; a hallucinated "You" pastes garbage into the user's document.
enum SilenceArtifact {
    /// The classic Whisper silence hallucinations, normalized form.
    private static let phrases: Set<String> = [
        "you", "thank you", "thanks", "thank you for watching",
        "thanks for watching", "bye", "bye bye", "okay", "so", "the",
        "uh", "um", "hmm", "mm", "oh", "yeah"
    ]

    /// Whisper's own literal non-speech tags, matched exactly rather than
    /// through `normalize()` — these are fixed-format model vocabulary, not
    /// natural language, and normalizing away the brackets would risk
    /// matching someone actually saying the bare word ("Music").
    private static let nonSpeechMarkers: Set<String> = [
        "[BLANK_AUDIO]", "[Music]"
    ]

    /// Real speech RMS, even at desk distance, sits near or above this;
    /// breaths and room tone sit well below.
    static let maxPlausibleRMSdB = -36.0

    static func isArtifact(_ transcript: String, rmsDB: Double) -> Bool {
        guard rmsDB < maxPlausibleRMSdB else { return false }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if nonSpeechMarkers.contains(trimmed) { return true }
        return phrases.contains(normalize(trimmed))
    }

    /// Removes literal ASR unknown-token markers — Parakeet emits "<unk>" on
    /// audio it can't decode, and five of them once typed into a document
    /// (field 2026-08-19). Never legitimate text; stripped before anything
    /// else sees the transcript. An all-markers transcript strips to empty
    /// and takes the existing "Nothing to write" path.
    static func strippingUnknownTokens(_ text: String) -> String {
        guard text.localizedCaseInsensitiveContains("<unk>") else { return text }
        return text
            .replacingOccurrences(of: #"(?i)<unk>[,.]?\s?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercase, letters-and-spaces only, collapsed whitespace — so
    /// "Thank you." and "thank  you" both hit the set.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isWhitespace }
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
