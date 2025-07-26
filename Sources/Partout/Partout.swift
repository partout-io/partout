// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

// MARK: Core

@_exported import PartoutCore
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
@_exported import PartoutAPIBundle
#endif

// MARK: - Vendors

@_exported import _PartoutVendorsPortable
#if canImport(_PartoutVendorsApple)
@_exported import _PartoutVendorsApple
@_exported import _PartoutVendorsAppleNE
#endif
