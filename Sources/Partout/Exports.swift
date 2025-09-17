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
#endif

#if PARTOUT_WIREGUARD
@_exported import PartoutWireGuard
#endif

#endif
