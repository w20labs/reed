import Foundation

/// The cleanup tiers. `off` inserts raw ASR text; `basic` is a
/// conservative rules pass (never changes meaning); `ai` uses Apple's on-device
/// Foundation Models (macOS 26+), falling back to `basic` when unavailable.
enum LocalCleanupTier: String, CaseIterable, Identifiable {
    case off
    case basic
    case ai

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "raw"
        case .basic: return "basic"
        case .ai: return "on-device AI"
        }
    }
}
