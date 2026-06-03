// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

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

/// Flags for ``DNSResolver``.
public enum DNSResolverFlag: Sendable {
    case allAddresses
}

/// Performs DNS resolution.
public protocol DNSResolver: AnyObject, Sendable {
    /**
     Resolves a hostname asynchronously.

     - Parameter hostname: The hostname to resolve.
     - Parameter reachability: The optional ``ReachabilityInfo``.
     - Parameter timeout: The timeout in milliseconds.
     */
    func resolve(
        _ hostname: String,
        flags: Set<DNSResolverFlag>,
        reachability: ReachabilityInfo?,
        timeout: Int
    ) async throws -> [DNSRecord]
}

extension DNSResolver {
    public func resolve(_ hostname: String, flags: Set<DNSResolverFlag>, timeout: Int) async throws -> [DNSRecord] {
        try await resolve(hostname, flags: flags, reachability: nil, timeout: timeout)
    }
}
