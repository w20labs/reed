import AppKit
import XCTest
@testable import Reed

/// Pins the 2026-08-25 hardening batch pieces that are pure functions.
final class HardeningBatchTests: XCTestCase {
    @MainActor
    func testVocabAuditNoteIsContentFree() {
        // Support reports attach reed.log and promise "no transcripts" — the
        // audit note must never contain the substituted words.
        let result = CorrectionResult(
            text: "open Xcode now",
            substitutions: [Substitution(range: 5..<10, original: "x code",
                                         replacement: "Xcode",
                                         domain: .engineering, rule: "always")],
            formattedSpans: [FormattedSpan(range: 0..<4, pattern: "email")],
            activeDomains: [.general, .engineering])
        let note = Coordinator.vocabAuditNote(result)
        XCTAssertFalse(note.localizedCaseInsensitiveContains("x code"), note)
        XCTAssertFalse(note.localizedCaseInsensitiveContains("Xcode"), note)
        XCTAssertTrue(note.contains("subs=1"), note)
        XCTAssertTrue(note.contains("engineering/always"), note)
        XCTAssertTrue(note.contains("email"), note)
    }

    func testHotkeyComboRequiresPromisedModifier() {
        // The UI promises "⌃, ⌥, or ⌘ plus a key" — shift-only collides with
        // ordinary typing and must not be accepted.
        XCTAssertFalse(HotkeyRecorderField.hasRequiredModifier([.shift]))
        XCTAssertFalse(HotkeyRecorderField.hasRequiredModifier([]))
        XCTAssertTrue(HotkeyRecorderField.hasRequiredModifier([.control]))
        XCTAssertTrue(HotkeyRecorderField.hasRequiredModifier([.option, .shift]))
        XCTAssertTrue(HotkeyRecorderField.hasRequiredModifier([.command]))
    }
}
