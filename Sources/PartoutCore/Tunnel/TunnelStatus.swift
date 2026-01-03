// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// The status of a ``Tunnel``.
@frozen
public enum TunnelStatus: String {
    case inactive

    case activating

    case active

    case deactivating
}
