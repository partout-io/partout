// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension AsyncStream {
    @discardableResult
    public func nextElement() async -> Element? {
        var iterator = makeAsyncIterator()
        return await iterator.next()
    }
}

extension AsyncThrowingStream {
    @discardableResult
    public func nextElement() async throws -> Element? {
        var iterator = makeAsyncIterator()
        return try await iterator.next()
    }
}

extension AsyncStream where Element: Equatable & Sendable {
    public func removeDuplicates() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                var previous: Element?
                for await value in self {
                    guard !Task.isCancelled else {
                        break
                    }
                    guard value != previous else {
                        continue
                    }
                    continuation.yield(value)
                    previous = value
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

extension AsyncThrowingStream where Element: Equatable & Sendable {
    public func removeDuplicates() -> AsyncThrowingStream<Element, Error> where Error == Failure {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var previous: Element?
                    for try await value in self {
                        guard !Task.isCancelled else {
                            break
                        }
                        guard value != previous else {
                            continue
                        }
                        continuation.yield(value)
                        previous = value
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

extension AsyncStream where Element: Sendable {
    public func map<Other>(_ block: @escaping @Sendable (Element) -> Other) -> AsyncStream<Other> where Other: Sendable {
        AsyncStream<Other> { continuation in
            let task = Task {
                for await value in self {
                    guard !Task.isCancelled else {
                        break
                    }
                    continuation.yield(block(value))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func compactMap<Other>(_ block: @escaping @Sendable (Element) -> Other?) -> AsyncStream<Other> where Other: Sendable {
        AsyncStream<Other> { continuation in
            let task = Task {
                for await value in self {
                    guard !Task.isCancelled else {
                        break
                    }
                    if let mapped = block(value) {
                        continuation.yield(mapped)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

extension AsyncThrowingStream where Element: Sendable {
    public func ignoreErrors() -> AsyncStream<Element> {
        replaceError(with: nil)
    }

    public func replaceError(with element: @autoclosure @escaping @Sendable () -> Element?) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in self {
                        guard !Task.isCancelled else {
                            break
                        }
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    if let replacementValue = element() {
                        continuation.yield(replacementValue)
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
