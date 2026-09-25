import Foundation

/// Thrown by `withDeadline` when the operation misses its wall-clock deadline.
struct TimeoutError: LocalizedError {
    var errorDescription: String? { "The operation timed out." }
}

/// Runs an async operation with a hard wall-clock deadline. Returns the value,
/// rethrows the operation's error, or throws `TimeoutError` when it doesn't
/// finish in time — in which case the operation is cancelled and its eventual
/// result discarded.
///
/// Unlike a `Task.sleep` race inside a task group (which still awaits every
/// child at scope exit), the caller here unblocks *at the deadline* even when
/// the underlying work ignores cooperative cancellation — e.g. an on-device
/// model inference already in flight. That is exactly the "spinner hangs
/// forever" case this guards against.
func withDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let box = OutcomeBox<T>()
    let once = DeadlineOnce()
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let work = Task {
            let outcome: Result<T, Error>
            do {
                outcome = .success(try await operation())
            } catch {
                outcome = .failure(error)
            }
            if once.claim() {
                box.outcome = outcome
                cont.resume()
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if once.claim() {
                work.cancel()
                box.outcome = .failure(TimeoutError())
                cont.resume()
            }
        }
    }
    // `once.claim()` guarantees exactly one writer set `outcome` before resuming.
    return try box.outcome!.get()
}

/// Carries the operation's outcome out of the continuation without requiring
/// `Result<T, Error>` itself to be `Sendable` (existential `Error` is not).
private final class OutcomeBox<T>: @unchecked Sendable {
    var outcome: Result<T, Error>?
}

/// Ensures exactly one of {operation completes, deadline fires} resumes the
/// continuation and writes the outcome.
private final class DeadlineOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
