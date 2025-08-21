// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

// MARK: Core

@_exported import PartoutCore
@_exported import PartoutPortable
@_exported import PartoutProviders

// MARK: - Optional

#if canImport(PartoutOpenVPN)
@_exported import PartoutOpenVPN
#endif

#if canImport(PartoutWireGuard)
@_exported import PartoutWireGuard
#endif

#if canImport(PartoutAPI)
@_exported import PartoutAPI
#endif

// MARK: - Vendors

#if canImport(_PartoutOSApple)
@_exported import _PartoutOSApple
@_exported import _PartoutOSAppleNE
#endif
#if canImport(_PartoutOSLinux)
@_exported import _PartoutOSLinux
#endif
