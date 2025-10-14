// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

public actor Expectation {
    private var fulfilled = false

    private var waiters: [CheckedContinuation<Void, Error>] = []

    public init() {
    }

    public func fulfill() {
        guard !fulfilled else { return }
        fulfilled = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    public func fulfillment(timeout: Int) async throws {
        if fulfilled {
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Task 1: wait for fulfill
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task {
                        await self.enqueue(cont)
                    }
                }
            }

            // Task 2: timeout
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout) * NSEC_PER_MSEC)
                throw TimeoutError()
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func enqueue(_ cont: CheckedContinuation<Void, Error>) {
        if fulfilled {
            cont.resume()
        } else {
            waiters.append(cont)
        }
    }

    struct TimeoutError: Error {}
}
