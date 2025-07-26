// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutVendorsPortable_C
import Foundation

extension Data {
    public init(zeroing zd: UnsafeMutablePointer<zeroing_data_t>) {
        let count = zd.pointee.length
        self.init(
            bytesNoCopy: zd.pointee.bytes,
            count: count,
            deallocator: .custom { _, _ in
                zd_free(zd)
            }
        )
    }
}
