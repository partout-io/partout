// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH

@_exported import PartoutInterfaces

#if canImport(PartoutOpenVPN)
@_exported import PartoutOpenVPN
#if canImport(PartoutOpenVPNCross)
@_exported import PartoutOpenVPNCross
#endif
#if canImport(PartoutOpenVPNLegacy)
@_exported import PartoutOpenVPNLegacy
#endif
#endif

#if canImport(PartoutWireGuard)
@_exported import PartoutWireGuard
#if canImport(PartoutWireGuardCross)
@_exported import PartoutWireGuardCross
#endif
#if canImport(PartoutWireGuardLegacy)
@_exported import PartoutWireGuardLegacy
#endif
#endif

#endif
