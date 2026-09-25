import Foundation

/// Where the opt-in voice corpus lives, resolved without naming anyone's Mac.
///
/// The corpus is recordings and transcripts: it is gitignored, it is not part
/// of the public tree, and nothing in it may be committed to make a test pass.
/// Before this existed, eleven bench files each carried the same absolute path
/// into one developer's home directory as their default, which made those
/// tests unrunnable for anybody else and published that path.
///
/// Resolution order, first hit wins:
/// 1. `REED_VOICE_ROOT`, for a corpus kept anywhere.
/// 2. `voice-tests/` beside the repository, found from this file rather than
///    from the working directory, so it does not depend on where the runner
///    was started.
///
/// The benches that use this are opt-in and already skip when their inputs are
/// absent; `root` simply stops that skip from depending on one machine.
enum VoiceCorpus {
    /// The configured root, whether or not anything is there.
    static var root: String {
        if let configured = ProcessInfo.processInfo.environment["REED_VOICE_ROOT"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configured
        }
        return repoRoot.appendingPathComponent("voice-tests").path
    }

    /// The root only when it actually holds a corpus, so a caller can tell
    /// "not configured" from "configured but empty".
    static var availableRoot: String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return root
    }

    /// The repository root, derived from this file's location.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReedTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }
}
