// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A socket type between UDP and TCP.
@frozen
public enum SocketType: String, Sendable {

    /// UDP socket type.
    case udp = "UDP"

    /// TCP socket type.
    case tcp = "TCP"
}

/// A socket type with optional info about the IP endpoint.
@frozen
public enum IPSocketType: String, Sendable {

    /// UDP socket type.
    case udp = "UDP"

    /// TCP socket type.
    case tcp = "TCP"

    /// UDP socket type (IPv4).
    case udp4 = "UDP4"

    /// TCP socket type (IPv4).
    case tcp4 = "TCP4"

    /// UDP socket type (IPv6).
    case udp6 = "UDP6"

    /// TCP socket type (IPv6).
    case tcp6 = "TCP6"
}

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
