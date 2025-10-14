// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// The protocol used in DNS servers.
public enum DNSProtocol: String, Hashable, Codable, Sendable {

    /// The value to fall back to when unset.
    public static let fallback: DNSProtocol = .cleartext

    /// Standard cleartext DNS (port 53).
    case cleartext

    /// DNS over HTTPS.
    case https

    /// DNS over TLS (port 853).
    case tls
}
