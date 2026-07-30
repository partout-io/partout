// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension IPSocketType {
    public var plainType: SocketType {
        switch self {
        case .udp, .udp4, .udp6:
            return .udp
        case .tcp, .tcp4, .tcp6:
            return .tcp
        }
    }
}
