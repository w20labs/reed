import Foundation

/// Environment inputs for the gated benches, validated (review 2026-09-01):
/// `String.split` drops empty entries, so `REED_ASR_ENGINES=` measured
/// nothing and passed; `Int("0")` made `1...0` crash; an unknown arm name
/// ran under a made-up label. Every list is non-empty and known, every
/// count is positive, or the bench fails before it loads anything.
enum BenchEnv {
    struct Invalid: Error, CustomStringConvertible { let description: String }

    /// A comma-separated list: non-empty, no empty entries, and every entry
    /// in `allowed` when given.
    static func list(_ key: String, default defaultValue: String, allowed: Set<String>? = nil,
                     env: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
        let raw = env[key] ?? defaultValue
        let entries = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if entries.isEmpty || entries.contains(where: \.isEmpty) {
            throw Invalid(description: "\(key)='\(raw)' names nothing to run — a bench that measures nothing must not pass")
        }
        if let allowed, let unknown = entries.first(where: { !allowed.contains($0) }) {
            throw Invalid(description: "\(key) names '\(unknown)', which nothing can run (allowed: \(allowed.sorted().joined(separator: ", ")))")
        }
        return entries
    }

    /// A positive run count.
    static func count(_ key: String, default defaultValue: Int,
                      env: [String: String] = ProcessInfo.processInfo.environment) throws -> Int {
        let raw = env[key] ?? String(defaultValue)
        guard let value = Int(raw), value >= 1 else {
            throw Invalid(description: "\(key)='\(raw)' is not a positive run count")
        }
        return value
    }
}

/// Names the stage an error escaped from (review 2026-09-01: a one-off
/// `DecodingError.dataCorrupted` surfaced from an idle-bench run with no
/// indication of WHICH awaited call threw — model load, recognition,
/// cleanup — and could not be reproduced). Every model-touching stage in a
/// bench runs through here: the failure line then carries the stage and
/// the full reflected error, and a `BS|error|` line lands in the QA log.
enum BenchStage {
    struct Failure: Error, CustomStringConvertible {
        let stage: String
        let underlying: Error
        var description: String { "stage '\(stage)' failed: \(String(reflecting: underlying))" }
    }

    static func run<T>(_ stage: String, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch {
            print("BS|error|\(stage)|\(String(reflecting: error).replacingOccurrences(of: "\n", with: " "))")
            throw Failure(stage: stage, underlying: error)
        }
    }
}
