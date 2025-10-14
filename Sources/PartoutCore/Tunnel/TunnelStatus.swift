// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// The status of a ``Tunnel``.
@frozen
public enum TunnelStatus: String {
    case inactive

    case activating

    case active

    case deactivating
}
