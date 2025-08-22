// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@_exported import PartoutCore
@_exported import PartoutProviders
@_exported import _PartoutOSWrapper

// MARK: - Optional

#if canImport(PartoutAPI)
@_exported import PartoutAPI
#endif

#if canImport(PartoutOpenVPN)
@_exported import PartoutOpenVPN
#endif

#if canImport(PartoutWireGuard)
@_exported import PartoutWireGuard
#endif
