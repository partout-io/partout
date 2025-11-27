// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// Implementation of ``PRNGProtocol`` with the OS C library.
public final class PlatformPRNG: PRNGProtocol {
    public init() {
    }

    public func uint32() -> UInt32 {
        fatalError("Not supported")
    }

    public func data(length: Int) -> Data {
        precondition(length > 0)
        let randomData = pp_zd_create(length)
        guard pp_prng_do(randomData.pointee.bytes, length) else {
            fatalError("pp_prng_do() failed")
        }
        return Data.zeroing(randomData)
    }
}
