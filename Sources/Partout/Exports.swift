// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH

@_exported import PartoutCore
@_exported import PartoutOS
@_exported import PartoutProviders

// MARK: - Optional

#if PARTOUT_API
@_exported import PartoutAPI
#endif

#if PARTOUT_OPENVPN
@_exported import PartoutOpenVPN
#if canImport(PartoutOpenVPNCross)
@_exported import PartoutOpenVPNCross
#endif
#if canImport(PartoutOpenVPNLegacy)
@_exported import PartoutOpenVPNLegacy
#endif
#endif

#if PARTOUT_WIREGUARD
@_exported import PartoutWireGuard
#if canImport(PartoutWireGuardCross)
@_exported import PartoutWireGuardCross
#endif
#if canImport(PartoutWireGuardLegacy)
@_exported import PartoutWireGuardLegacy
#endif
#endif

#endif
