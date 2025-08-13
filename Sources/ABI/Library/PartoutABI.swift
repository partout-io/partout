// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutVendorsPortable_C
import Foundation

@_cdecl("partout_version")
public func partout_version() -> UnsafePointer<CChar> {
    UnsafePointer(pp_dup("Partout 0.99.x"))
}
