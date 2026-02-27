// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

@_exported import Dispatch
#if canImport(FoundationEssentials)
@_exported import FoundationEssentials
public typealias UUID = FoundationEssentials.UUID
#else
@_exported import Foundation
public typealias UUID = Foundation.UUID
#endif

#if canImport(Android)
@_exported import Android
#elseif canImport(Glibc)
@_exported import Glibc
#elseif canImport(WinSDK)
@_exported import ucrt
@_exported import WinSDK
#endif

#if MINIF_COMPAT
public typealias IndexSet = [Int]
public let NSEC_PER_MSEC: UInt64 = 1000000
public let NSEC_PER_SEC: UInt64 = 1000000000
#endif

extension UUID: RandomlyInitialized {}
