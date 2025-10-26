// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Result of ``DNSResolver/resolve(_:timeout:)``.
public struct DNSRecord: Hashable, Codable, Sendable {

    /// Address string.
    public let address: String

    /// `true` if IPv6.
    public let isIPv6: Bool

    public init(address: String, isIPv6: Bool) {
        self.address = address
        self.isIPv6 = isIPv6
    }
}

/// Performs DNS resolution.
public protocol DNSResolver: AnyObject, Sendable {

    /**
     Resolves a hostname asynchronously.

     - Parameter hostname: The hostname to resolve.
     - Parameter timeout: The timeout in milliseconds.
     */
    func resolve(_ hostname: String, timeout: Int) async throws -> [DNSRecord]
}
