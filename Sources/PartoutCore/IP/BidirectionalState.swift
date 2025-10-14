// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// A generic structure holding a pair of inbound/outbound states.
public struct BidirectionalState<T> {
    private let resetValue: T

    /// The inbound state.
    public var inbound: T

    /// The outbound state.
    public var outbound: T

    /**
     Returns current state as a pair.
     
     - Returns: Current state as a pair, inbound first.
     */
    public var pair: (T, T) {
        return (inbound, outbound)
    }

    /**
     Inits state with a value that will later be reused by ``reset()``.

     - Parameter value: The value to initialize with and reset to.
     */
    public init(withResetValue value: T) {
        inbound = value
        outbound = value
        resetValue = value
    }

    /**
     Resets state to the value provided with ``init(withResetValue:)``.
     */
    public mutating func reset() {
        inbound = resetValue
        outbound = resetValue
    }
}
