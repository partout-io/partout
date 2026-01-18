// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE

@_exported import PartoutCore
@_exported import PartoutOS

// MARK: - Optional

#if PARTOUT_OPENVPN
@_exported import PartoutOpenVPN
#if !PARTOUT_FOR_PREVIEWS
@_exported import PartoutOpenVPNConnection
#endif
#endif

#if PARTOUT_WIREGUARD
@_exported import PartoutWireGuard
#if !PARTOUT_FOR_PREVIEWS
@_exported import PartoutWireGuardConnection
#endif
#endif

#endif
