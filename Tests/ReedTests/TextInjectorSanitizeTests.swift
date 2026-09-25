import XCTest
@testable import Reed

/// Pins `TextInjector.sanitize`, the guard that keeps untrusted (server-/model-
/// controlled) injected text from driving a terminal when the clipboard+⌘V
/// fallback lands in one: strip C0 controls except `\n`/`\t` (ESC/CR always),
/// drop DEL, and suppress trailing newlines so a paste never auto-executes.
final class TextInjectorSanitizeTests: XCTestCase {
    func testPlainTextUnchanged() {
        XCTAssertEqual(TextInjector.sanitize("Hello, world."), "Hello, world.")
    }

    func testInteriorNewlinesAndTabsPreservedForOrdinaryApps() {
        // Multi-paragraph output keeps its interior structure in editors,
        // email, docs; only trailing newlines go.
        XCTAssertEqual(TextInjector.sanitize("line1\nline2\tcol", forTarget: "com.apple.TextEdit"),
                       "line1\nline2\tcol")
        XCTAssertEqual(TextInjector.sanitize("para1\n\npara2\n", forTarget: nil),
                       "para1\n\npara2")
    }

    func testTerminalTargetsFlattenInteriorNewlinesAndTabs() {
        // 2026-08-25 finding: "safe command\nsecond command" submits the
        // first line in any shell without multiline-paste protection, and an
        // interior tab triggers completion. Every terminal in the taxonomy
        // gets the flatten — including Tabby, which was missing entirely.
        for terminal in ["com.apple.Terminal", "com.googlecode.iterm2", "org.tabby",
                         "dev.warp.Warp-Stable", "net.kovidgoyal.kitty"] {
            XCTAssertEqual(
                TextInjector.sanitize("safe command\nsecond command", forTarget: terminal),
                "safe command second command", terminal)
            XCTAssertEqual(
                TextInjector.sanitize("ls\t-la\n\n", forTarget: terminal),
                "ls -la", terminal)
        }
    }

    func testStripsEscapeSequence() {
        // ESC (0x1B) starts terminal escape sequences (clear screen, OSC 52…).
        XCTAssertEqual(TextInjector.sanitize("ls\u{1B}[2Jrm"), "ls[2Jrm")
    }

    func testStripsCarriageReturnAndOtherC0() {
        // A lone CR would return the cursor / can submit at some prompts.
        XCTAssertEqual(TextInjector.sanitize("rm -rf /\r"), "rm -rf /")
        // NUL and BEL are dropped too.
        XCTAssertEqual(TextInjector.sanitize("a\u{00}b\u{07}c"), "abc")
    }

    func testStripsDEL() {
        XCTAssertEqual(TextInjector.sanitize("a\u{7F}b"), "ab")
    }

    func testStripsC1Controls() {
        // U+009B is a single-byte CSI — the one-character equivalent of
        // ESC-[ — so it must go the same way ESC does. U+0085 (NEL) and the
        // rest of the C1 block are never legitimate dictation output.
        XCTAssertEqual(TextInjector.sanitize("ls\u{9B}2Jrm"), "ls2Jrm")
        XCTAssertEqual(TextInjector.sanitize("a\u{85}b"), "ab")
        XCTAssertEqual(TextInjector.sanitize("a\u{80}\u{9F}b"), "ab")
    }

    func testTrimsTrailingNewlines() {
        // The core terminal auto-submit vector: a trailing newline runs the line.
        XCTAssertEqual(TextInjector.sanitize("echo hi\n"), "echo hi")
        XCTAssertEqual(TextInjector.sanitize("echo hi\n\n\n"), "echo hi")
    }

    func testTrailingCRLFFullyTrimmed() {
        // CR is stripped, then the trailing LF is trimmed — nothing left to submit.
        XCTAssertEqual(TextInjector.sanitize("echo hi\r\n"), "echo hi")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(TextInjector.sanitize(""), "")
    }

    func testUnicodeContentPreserved() {
        let text = "café — naïve 日本語 🎉"
        XCTAssertEqual(TextInjector.sanitize(text), text)
    }
}
