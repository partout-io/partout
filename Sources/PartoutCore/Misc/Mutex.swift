// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

final class Mutex: @unchecked Sendable {
    private let semaphore: DispatchSemaphore

    init() {
        semaphore = DispatchSemaphore(value: 1)
    }

    func lock() {
        semaphore.wait()
    }

    func unlock() {
        semaphore.signal()
    }
}
