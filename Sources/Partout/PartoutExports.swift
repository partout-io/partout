// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE

@_exported import PartoutCore
@_exported import PartoutOpenVPN
@_exported import PartoutOS
@_exported import PartoutWireGuard

// MARK: - Optional

#if PARTOUT_OPENVPN
@_exported import PartoutOpenVPNConnection
#endif

#if PARTOUT_WIREGUARD
@_exported import PartoutWireGuardConnection
#endif

#endif
