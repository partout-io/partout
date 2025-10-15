// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

#if os(Android)
@_exported import Android
#elseif os(Windows)
public let AF_INET: Int32 = 2
public let AF_INET6: Int32 = 10
#endif

#if !os(Darwin)
let NSEC_PER_MSEC: UInt64 = 1000000
let NSEC_PER_SEC: UInt64 = 1000000000
#endif
