// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(ObjectiveC)

@available(*, deprecated, message: "Not cross-platform")
public func stream<O, V>(
    for keyPath: KeyPath<O, V>,
    of object: O,
    filter: @escaping @Sendable (V) -> Bool
) -> AsyncStream<V> where O: NSObject, V: Sendable {
    AsyncStream { [weak object] continuation in
        let observation = object?.observe(keyPath, options: [.initial, .new]) { _, change in
            if let newValue = change.newValue, filter(newValue) {
                continuation.yield(newValue)
            }
        }
        continuation.onTermination = { @Sendable _ in
            observation?.invalidate()
        }
    }
}

#endif
