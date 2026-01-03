// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

extension Data {
    public static func zeroing(_ zd: UnsafeMutableRawPointer) -> Self {
        let ptr = zd.assumingMemoryBound(to: pp_zd.self)
        return Data(rawZeroing: ptr)
    }

    init(rawZeroing zd: UnsafeMutablePointer<pp_zd>) {
        let count = zd.pointee.length
        self.init(
            bytesNoCopy: zd.pointee.bytes,
            count: count,
            customDeallocator: {
                pp_zd_free(zd)
            }
        )
    }
}
