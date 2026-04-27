// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package final class SemaphoreMutex: @unchecked Sendable {
    private let semaphore: DispatchSemaphore

    package init() {
        semaphore = DispatchSemaphore(value: 1)
    }

    package func lock() {
        semaphore.wait()
    }

    package func unlock() {
        semaphore.signal()
    }
}
