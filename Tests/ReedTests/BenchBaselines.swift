import Foundation

/// Committed regression ceilings for the gated benches (audit 2026-08-30:
/// "no bench fails on regression"). Lives next to the code so a threshold
/// change is a reviewed diff, not a Python constant nobody reads.
///
/// Fail closed (review 2026-09-01): a missing or malformed file is an
/// error, never "measured, not gated" — that silently disarmed every
/// ceiling. Only an ABSENT KEY means ungated, and only for arms a bench
/// declares experimental; its known arms `require` their line.
enum BenchBaselines {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ReedTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("docs/bench/baselines.json")

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String), malformed(String), notANumber([String]), missing([String])
        var description: String {
            switch self {
            case .unreadable(let why): return "ceilings file unreadable (docs/bench/baselines.json): \(why)"
            case .malformed(let why): return "ceilings file malformed (docs/bench/baselines.json): \(why)"
            case .notANumber(let path): return "ceiling \(path.joined(separator: ".")) is not a number"
            case .missing(let path): return "no committed ceiling \(path.joined(separator: ".")) for a known arm — add it to docs/bench/baselines.json"
            }
        }
    }

    /// Numeric ceiling at a key path like ["p1", "e2e_p95_ms", "v3"], or nil
    /// when that key is absent. Throws when the file cannot be read or
    /// parsed, or the key exists but is not a number.
    static func ceiling(_ path: [String], file: URL = url) throws -> Double? {
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw Failure.unreadable(error.localizedDescription) }
        var node: Any
        do { node = try JSONSerialization.jsonObject(with: data) } catch { throw Failure.malformed(error.localizedDescription) }
        for key in path {
            guard let dict = node as? [String: Any] else { throw Failure.malformed("\(path.joined(separator: ".")): expected an object") }
            guard let next = dict[key] else { return nil }
            node = next
        }
        // JSON true/false also bridge to NSNumber; a boolean is not a ceiling.
        guard let number = node as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw Failure.notANumber(path) }
        return number.doubleValue
    }

    /// A known arm's ceiling: absent is a failure too.
    static func require(_ path: [String], file: URL = url) throws -> Double {
        guard let value = try ceiling(path, file: file) else { throw Failure.missing(path) }
        return value
    }
}
