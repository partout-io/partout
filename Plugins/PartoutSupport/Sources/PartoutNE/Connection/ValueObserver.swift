//
//  ValueObserver.swift
//  Partout
//
//  Created by Davide De Rosa on 3/29/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

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
