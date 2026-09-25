import XCTest
@testable import Reed

/// Denoise, proven to run, for every bench on the pipeline path (review
/// 2026-09-08). Under `swift test` there is no bundle, so the shared
/// denoiser found no model, disabled itself and passed raw audio to every
/// bench without a word. This points the shared instance at the repo's
/// model — the file build-app.sh copies into the bundle — runs one real
/// inference on a real clip and fails the bench unless it was processed.
/// Load or inference failure fails the run; nothing falls back to raw.
enum BenchDenoise {
    static let modelURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/Models/fastenhancer_tiny_16k.onnx")

    /// Outcomes a measured call may have: the audio was denoised, or it was
    /// genuine silence with nothing to denoise. Everything else — no model,
    /// a load or inference failure, the coordinator stage's deadline or
    /// watchdog bypass — fails the bench the moment it happens.
    static let acceptable: Set<Denoiser.Outcome> = [.processed, .skippedSilence]

    /// Call before measuring. Throws (and fails) when denoise cannot run,
    /// and from then on every outcome on any path — direct calls and the
    /// coordinator stage's bypasses — is checked (review 2026-09-08).
    static func require(file: StaticString = #filePath, line: UInt = #line) async throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            XCTFail("denoise model missing at \(modelURL.path)", file: file, line: line)
            throw Failure.missing
        }
        Denoiser.modelURLOverrideForTests = modelURL
        Denoiser.outcomeObserverForTests = nil
        await Denoiser.shared.reload()   // an earlier test may have disabled it for the session
        let clip = probeClip()
        let outcome = await Denoiser.shared.processReporting(wav: clip).outcome
        guard outcome == .processed else {
            XCTFail("denoise did not run on the probe clip: \(outcome.rawValue)", file: file, line: line)
            throw Failure.notProcessed(outcome)
        }
        let counter = Counter.shared
        counter.reset()
        Denoiser.outcomeObserverForTests = { outcome in
            counter.note(outcome)
            if !acceptable.contains(outcome) {
                XCTFail("a measured call did not denoise: \(outcome.rawValue)", file: file, line: line)
            }
        }
    }

    /// Counts by outcome since `require`, for a bench's env line.
    static var tally: String { Counter.shared.tally }

    /// Every outcome seen since `require`, so a test can prove the observer saw a fault.
    static var seen: [Denoiser.Outcome] { Counter.shared.seen }

    final class Counter: @unchecked Sendable {
        static let shared = Counter()
        private let lock = NSLock()
        private var counts: [Denoiser.Outcome: Int] = [:]
        private(set) var seen: [Denoiser.Outcome] = []
        func note(_ outcome: Denoiser.Outcome) { lock.lock(); counts[outcome, default: 0] += 1; seen.append(outcome); lock.unlock() }
        func reset() { lock.lock(); counts = [:]; seen = []; lock.unlock() }
        var tally: String { lock.lock(); defer { lock.unlock() }; return counts.keys.sorted { $0.rawValue < $1.rawValue }.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " ") }
    }

    /// One call's outcome must be `processed`; anything else fails the bench.
    static func assertProcessed(_ outcome: Denoiser.Outcome, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome, .processed, "denoise did not run on \(what)", file: file, line: line)
    }

    enum Failure: Error { case missing, notProcessed(Denoiser.Outcome) }

    /// A second of speech-shaped noise, above the silence floor.
    private static func probeClip() -> Data {
        var seed: UInt32 = 11
        let samples: [Int16] = (0..<16_000).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int16(truncatingIfNeeded: Int(seed >> 16) % 8_001 - 4_000)
        }
        return BenchReplay.wrap(samples.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
