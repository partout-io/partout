// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE

@_exported import PartoutCore
@_exported import PartoutOS

// MARK: - Optional

#if PARTOUT_OPENVPN
@_exported import PartoutOpenVPN
#endif

#if PARTOUT_WIREGUARD
@_exported import PartoutWireGuard
#endif

#endif
