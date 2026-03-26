// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE

@_exported import PartoutCore
@_exported import PartoutOS

// MARK: - Optional

@_exported import PartoutOpenVPN
#if PARTOUT_OPENVPN
@_exported import PartoutOpenVPNConnection
#endif

@_exported import PartoutWireGuard
#if PARTOUT_WIREGUARD
@_exported import PartoutWireGuardConnection
#endif

#endif
