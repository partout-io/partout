// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Observes KVO updates asynchronously.
actor SafeValueObserver<O> where O: NSObject {
    private struct PendingWait {
        let continuation: CheckedContinuation<Void, Error>

        var observer: NSKeyValueObservation?

        var timeoutTask: Task<Void, Never>?
    }

    private let subject: O

    private var nextWaitId: UInt64

    private var pendingWaitId: UInt64?

    private var pendingWait: PendingWait?

    init(_ subject: O) {
        self.subject = subject
        nextWaitId = 0
    }

    func waitForValue<V>(
        on keyPath: KeyPath<O, V>,
        timeout: Int,
        onValue: @escaping (V) throws -> Bool
    ) async throws {
        guard timeout >= 0 else {
            throw PartoutError(.invalidValue, "timeout")
        }
        try Task.checkCancellation()
        guard pendingWait == nil else {
            throw PartoutError(.invalidValue, "waitForValue")
        }

        let waitId = nextWaitId
        nextWaitId += 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startWaiting(
                    waitId,
                    on: keyPath,
                    timeout: timeout,
                    continuation: continuation,
                    onValue: onValue
                )
            }
        } onCancel: {
            Task {
                await self.cancelWait(waitId)
            }
        }
    }
}

private extension SafeValueObserver {
    func startWaiting<V>(
        _ waitId: UInt64,
        on keyPath: KeyPath<O, V>,
        timeout: Int,
        continuation: CheckedContinuation<Void, Error>,
        onValue: @escaping (V) throws -> Bool
    ) {
        guard pendingWait == nil else {
            continuation.resume(throwing: PartoutError(.invalidValue, "waitForValue"))
            return
        }
        pendingWaitId = waitId
        pendingWait = PendingWait(continuation: continuation)

        pendingWait?.timeoutTask = Task {
            do {
                try await Task.sleep(milliseconds: timeout)
            } catch {
                return
            }
            resumeWait(waitId, with: .failure(PartoutError(.timeout)))
        }
        pendingWait?.observer = subject.observe(keyPath, options: [.initial, .new]) { _, change in
            guard let value = change.newValue else {
                return
            }
            Task { [weak self] in
                await self?.handleValue(waitId, value, onValue: onValue)
            }
        }
    }

    func handleValue<V>(
        _ waitId: UInt64,
        _ value: V,
        onValue: @escaping (V) throws -> Bool
    ) {
        guard pendingWaitId == waitId, pendingWait != nil else {
            return
        }
        do {
            if try onValue(value) {
                resumeWait(waitId, with: .success(()))
            }
        } catch {
            resumeWait(waitId, with: .failure(error))
        }
    }

    func cancelWait(_ waitId: UInt64) {
        resumeWait(waitId, with: .failure(CancellationError()))
    }

    func resumeWait(_ waitId: UInt64, with result: Result<Void, Error>) {
        guard pendingWaitId == waitId, let pendingWait else {
            return
        }
        pendingWaitId = nil
        self.pendingWait = nil
        pendingWait.timeoutTask?.cancel()
        pendingWait.observer?.invalidate()
        switch result {
        case .success:
            pendingWait.continuation.resume()

        case .failure(let error):
            pendingWait.continuation.resume(throwing: error)
        }
    }
}
