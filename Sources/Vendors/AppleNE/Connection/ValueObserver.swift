// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

/// Observes KVO updates asynchronously.
actor ValueObserver<O> where O: NSObject {
    private weak var subject: O?

    private var waitObserver: NSKeyValueObservation?

    init(_ subject: O) {
        self.subject = subject
    }

    func waitForValue<V>(
        on keyPath: KeyPath<O, V>,
        timeout: Int,
        onValue: @escaping (V) throws -> Bool
    ) async throws {
        return try await withCheckedThrowingContinuation { continuation in

            // schedule timeout
            Task {
                try await Task.sleep(milliseconds: timeout)
                guard isWaiting() == true else {
                    return
                }
                continuation.resume(throwing: PartoutError(.timeout))
                stopWaiting()
            }

            // schedule observation
            waitSubject(on: keyPath) { [weak self] value in
                guard await self?.isWaiting() == true else {
                    return
                }
                do {
                    if try onValue(value) {
                        continuation.resume()
                        await self?.stopWaiting()
                    } else {
                        // ignored
                    }
                } catch {
                    continuation.resume(throwing: error)
                    await self?.stopWaiting()
                }
            }
        }
    }
}

private extension ValueObserver {
    func waitSubject<V>(on keyPath: KeyPath<O, V>, onValue: @escaping (V) async -> Void) {

        // could also sink subject?.publisher(for: keyPath)
        waitObserver = subject?.observe(keyPath, options: [.initial, .new]) { object, _ in
            Task {
                await onValue(object[keyPath: keyPath])
            }
        }
    }

    func isWaiting() -> Bool {
        waitObserver != nil
    }

    func stopWaiting() {
        waitObserver = nil
    }
}
