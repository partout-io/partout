// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutVendorsPortable_C
import Foundation

extension Data {
    public init(zeroing zd: UnsafeMutablePointer<pp_zd>) {
        let count = zd.pointee.length
        self.init(
            bytesNoCopy: zd.pointee.bytes,
            count: count,
            deallocator: .custom { _, _ in
                pp_zd_free(zd)
            }
        )
    }
}
