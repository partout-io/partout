// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

@preconcurrency import Combine
extension Publisher where Output: Sendable {
    @available(*, deprecated, message: "This may produce a retain cycle if the Publisher was created from KVO .publisher(for:)")
    public func stream() -> AsyncThrowingStream<Output, Error> {
        AsyncThrowingStream { continuation in
            let cancellable = sink(
                receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        continuation.finish()
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    }
                },
                receiveValue: { value in
                    continuation.yield(value)
                }
            )
            continuation.onTermination = { @Sendable _ in
                cancellable.cancel()
            }
        }
    }
}
