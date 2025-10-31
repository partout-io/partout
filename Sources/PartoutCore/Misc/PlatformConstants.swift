// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

#if canImport(Android)
@_exported import Android
#elseif canImport(Darwin)
@_exported import Darwin
#elseif canImport(Linux)
@_exported import Linux
#elseif canImport(WinSDK)
@_exported import WinSDK
#endif

#if !canImport(Darwin)
let NSEC_PER_MSEC: UInt64 = 1000000
let NSEC_PER_SEC: UInt64 = 1000000000
#endif
