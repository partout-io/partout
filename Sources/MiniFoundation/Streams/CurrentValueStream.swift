// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Dispatch

/// Replacement for `CurrentValueSubject`.
public final class CurrentValueStream<T>: @unchecked Sendable where T: Sendable {
    let queue = DispatchQueue(label: "CurrentValueStream")

    var observers: [UniqueID: AsyncStream<T>.Continuation] = [:]

    var throwingObservers: [UniqueID: AsyncThrowingStream<T, Error>.Continuation] = [:]

    var isFinished = false

    private var latestValue: T

    public init(_ initialValue: T) {
        latestValue = initialValue
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
        let id = UniqueID() // Best-effort, assume nonexistent observer id
        return AsyncStream { [weak self] continuation in
            guard let self else {
                return
            }
            queue.async {
                self.observers[id] = continuation
                continuation.yield(self.latestValue)
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.observers.removeValue(forKey: id)
                }
            }
        }
    }

    public func subscribeThrowing() -> AsyncThrowingStream<T, Error> {
        let id = UniqueID() // Best-effort, assume nonexistent observer id
        return AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                return
            }
            queue.async {
                self.throwingObservers[id] = continuation
                continuation.yield(self.latestValue)
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
            latestValue = value
            for continuation in observers.values {
                continuation.yield(value)
            }
            for continuation in throwingObservers.values {
                continuation.yield(value)
            }
        }
    }

    public var value: T {
        queue.sync {
            latestValue
        }
    }
}

extension CurrentValueStream: SubjectStreamInternal {
}
