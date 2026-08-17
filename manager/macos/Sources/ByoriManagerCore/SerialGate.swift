import Foundation

/// Serializes work that must never overlap.
///
/// Actor isolation alone does not provide this: an actor method that suspends on
/// `await` lets another call into the actor at that suspension point, so N
/// concurrent callers of one actor method produce N overlapping requests. Wrap
/// the part that must be exclusive in `perform`.
///
/// Fair enough for its purpose, not strictly FIFO: a caller resumed by the
/// previous holder re-checks the flag and rejoins the queue if a newcomer took
/// the slot first. Every release resumes one waiter, so progress is preserved.
actor SerialGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        while isBusy {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        isBusy = true
    }

    private func release() {
        isBusy = false
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}
