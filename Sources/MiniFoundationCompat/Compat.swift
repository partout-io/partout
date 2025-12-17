// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public enum Compat {}

#if canImport(Android)
@_exported import Android
#elseif canImport(Glibc)
@_exported import Glibc
#elseif canImport(WinSDK)
@_exported import ucrt
@_exported import WinSDK
#endif

@_exported import Dispatch
public let NSEC_PER_MSEC: UInt64 = 1000000
public let NSEC_PER_SEC: UInt64 = 1000000000

#if !USE_CMAKE
@_exported import MiniFoundationCore
#endif
