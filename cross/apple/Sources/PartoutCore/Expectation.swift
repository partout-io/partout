// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public actor Expectation {
    private struct PendingWait {
        let continuation: CheckedContinuation<Void, Error>

        var timeoutTask: Task<Void, Never>?
    }

    private var fulfilled = false

    private var nextWaiterId = 0

    private var waiters: [Int: PendingWait] = [:]

    public init() {
    }

    public func fulfill() {
        guard !fulfilled else { return }
        fulfilled = true
        let pendingWaiters = waiters.values
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume()
        }
    }

    public func fulfillment(timeout: Int) async throws {
        if fulfilled {
            return
        }

        try Task.checkCancellation()

        let waiterId = nextWaiterId
        nextWaiterId += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startWaiting(waiterId, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterId)
            }
        }
    }

    private func startWaiting(
        _ waiterId: Int,
        timeout: Int,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard !fulfilled else {
            continuation.resume()
            return
        }

        waiters[waiterId] = PendingWait(continuation: continuation)
        if timeout < .max {
            waiters[waiterId]?.timeoutTask = Task {
                do {
                    try await Task.sleep(for: .milliseconds(timeout))
                } catch {
                    return
                }
                resumeWait(waiterId, with: .failure(TimeoutError()))
            }
        }
    }

    private func cancelWaiter(_ waiterId: Int) {
        resumeWait(waiterId, with: .failure(CancellationError()))
    }

    private func resumeWait(_ waiterId: Int, with result: Result<Void, Error>) {
        guard let waiter = waiters.removeValue(forKey: waiterId) else { return }
        waiter.timeoutTask?.cancel()
        switch result {
        case .success:
            waiter.continuation.resume()

        case .failure(let error):
            waiter.continuation.resume(throwing: error)
        }
    }

    public struct TimeoutError: Error {}
}
