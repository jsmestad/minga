import Synchronization

/// A clock whose time moves only when a test calls `advance(by:)`.
///
/// Lifecycle code that sleeps on this clock suspends until the test advances
/// time past its deadline. Cancelling a suspended task removes its sleeper and
/// makes the sleep throw `CancellationError` at once, so a test can prove that
/// cancelled work never resumes. `waitForSleepers(_:)` lets a test wait until
/// the code under test has actually parked, without real delays or yield loops.
final class ManualClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var waiters: [Waiter] = []

        /// Removes and returns the waiters whose sleeper count is now satisfied.
        mutating func takeSatisfiedWaiters() -> [Waiter] {
            let satisfied = waiters.filter { sleepers.count >= $0.count }
            waiters.removeAll { sleepers.count >= $0.count }
            return satisfied
        }
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }

    var minimumResolution: Duration { .zero }

    /// Number of tasks currently suspended on this clock.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (immediate, waiters) = state.withLock { state -> (Result<Void, any Error>?, [Waiter]) in
                    // Checked under the lock so a concurrent cancellation either sees this sleeper or this check sees it.
                    if Task.isCancelled { return (.failure(CancellationError()), []) }
                    if deadline <= state.now { return (.success(()), []) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return (nil, state.takeSatisfiedWaiters())
                }
                if let immediate { continuation.resume(with: immediate) }
                for waiter in waiters { waiter.continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and resumes every sleeper whose deadline has been reached.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Suspends until at least `count` tasks are sleeping on this clock.
    func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.sleepers.count >= count { return true }
                state.waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
