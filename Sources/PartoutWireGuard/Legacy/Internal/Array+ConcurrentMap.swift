// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension Array {

    /// Returns an array containing the results of mapping the given closure over the sequence’s
    /// elements concurrently.
    ///
    /// - Parameters:
    ///   - queue: The queue for performing concurrent computations.
    ///            If the given queue is serial, the values are mapped in a serial fashion.
    ///            Pass `nil` to perform computations on the current queue.
    ///   - transform: the block to perform concurrent computations over the given element.
    /// - Returns: an array of concurrently computed values.
    func concurrentMap<U>(queue: DispatchQueue?, _ transform: @escaping @Sendable (Element) -> U) -> [U] where U: Sendable {
        nonisolated(unsafe) let copy = self
        nonisolated(unsafe) var result = [U?](repeating: nil, count: copy.count)
        let resultQueue = DispatchQueue(label: "ConcurrentMapQueue")

        let block = {
            DispatchQueue.concurrentPerform(iterations: copy.count) { index in
                let value = transform(copy[index])
                resultQueue.sync {
                    result[index] = value
                }
            }
        }
        if let queue {
            queue.sync(execute: block)
        } else {
            block()
        }

        return result.map { $0! }
    }
}
