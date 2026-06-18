// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A binary atomic state for mutual exclusion.
public final class SemaphoreMutex: @unchecked Sendable {
    private let semaphore: DispatchSemaphore

    public init() {
        semaphore = DispatchSemaphore(value: 1)
    }

    public func lock() {
        semaphore.wait()
    }

    public func unlock() {
        semaphore.signal()
    }

    @discardableResult
    public func with<T>(block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}
