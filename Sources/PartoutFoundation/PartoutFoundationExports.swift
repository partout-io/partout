// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// FIXME: #228, Until Foundation is dropped
//#if canImport(Android)
//@_exported import Android
//#elseif canImport(Darwin)
@_exported import Foundation
public typealias RegularExpression = NSRegularExpression
//#elseif canImport(Linux)
//@_exported import Linux
//#elseif canImport(WinSDK)
//@_exported import WinSDK
//#endif

#if !canImport(Darwin)
@_exported import Dispatch
public let NSEC_PER_MSEC: UInt64 = 1000000
public let NSEC_PER_SEC: UInt64 = 1000000000
#endif

