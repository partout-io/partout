// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C

public final class PRNG {
    public init() {
    }

    public func bytes(length: Int) -> [UInt8] {
        precondition(length > 0)
        var randomData = [UInt8](repeating: 0, count: length)
        randomData.withUnsafeMutableBytes {
            guard let addr = $0.baseAddress, minif_prng_do(addr, length) else {
                fatalError("minif_prng_do() failed")
            }
        }
        return randomData
    }
}
