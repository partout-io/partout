// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Dispatch

/// Replacement for completion values.
public enum SubjectStreamCompletion {
    case finished

    case failure(_ error: Error)
}

/// Replacement for `Subject`.
public protocol SubjectStream: AnyObject, Sendable {
    associatedtype T

    func send(_ value: T)

    func send(completion: SubjectStreamCompletion)

    func finish(throwing error: Error?)
}

protocol SubjectStreamInternal: SubjectStream {
    associatedtype ObserverID: RandomlyInitialized

    var queue: DispatchQueue { get }

    var observers: [ObserverID: AsyncStream<T>.Continuation] { get }

    var throwingObservers: [ObserverID: AsyncThrowingStream<T, Error>.Continuation] { get }

    var isFinished: Bool { get set }
}

extension SubjectStream {
    public func finish() {
        finish(throwing: nil)
    }
}

extension SubjectStream where T == Void {
    public func send() {
        send(())
    }
}

extension SubjectStreamInternal {
    public func send(completion: SubjectStreamCompletion) {
        switch completion {
        case .finished:
            finish()
        case .failure(let error):
            finish(throwing: error)
        }
    }

    public func finish(throwing error: Error?) {
        queue.async { [weak self] in
            guard let self, !isFinished else {
                return
            }
            isFinished = true
            for continuation in observers.values {
                continuation.finish()
            }
            for continuation in throwingObservers.values {
                if let error {
                    continuation.finish(throwing: error)
                    continue
                }
                continuation.finish()
            }
        }
    }
}
