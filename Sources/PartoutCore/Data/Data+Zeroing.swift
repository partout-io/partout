// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

extension Data {
    public static func zeroing(_ zd: UnsafeMutableRawPointer) -> Self {
        zd.withMemoryRebound(to: pp_zd.self, capacity: 1) { ptr in
            Data(rawZeroing: ptr)
        }
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
