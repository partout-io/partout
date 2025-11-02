// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Dispatch

/// Replacement of `PassthroughSubject`.
public final class PassthroughStream<T>: @unchecked Sendable where T: Sendable {
    let queue = DispatchQueue(label: "PassthroughStream")

    var observers: [UniqueID: AsyncStream<T>.Continuation] = [:]

    var throwingObservers: [UniqueID: AsyncThrowingStream<T, Error>.Continuation] = [:]

    var isFinished = false

    public init() {
    }

    deinit {
        observers.values.forEach {
            $0.finish()
        }
        throwingObservers.values.forEach {
            $0.finish()
        }
    }

    public func subscribe() -> AsyncStream<T> {
        let id = UniqueID() // best-effort, assume nonexistent observer id
        return AsyncStream { [weak self] continuation in
            guard let self else {
                return
            }
            queue.async {
                self.observers[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.observers.removeValue(forKey: id)
                }
            }
        }
    }

    public func subscribeThrowing() -> AsyncThrowingStream<T, Error> {
        let id = UniqueID() // best-effort, assume nonexistent observer id
        return AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                return
            }
            queue.async {
                self.throwingObservers[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.throwingObservers.removeValue(forKey: id)
                }
            }
        }
    }

    public func send(_ value: T) {
        queue.async { [weak self] in
            guard let self, !isFinished else {
                return
            }
            for continuation in observers.values {
                continuation.yield(value)
            }
            for continuation in throwingObservers.values {
                continuation.yield(value)
            }
        }
    }
}

extension PassthroughStream: SubjectStreamInternal {
}
