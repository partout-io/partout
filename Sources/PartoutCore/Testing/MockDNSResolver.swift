// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

public final class MockDNSResolver: DNSResolver, @unchecked Sendable {
    public var resolvedRecords: [String: [DNSRecord]] = [:]

    public var error: Error?

    public init() {
    }

    public func resolve(_ hostname: String, timeout: Int) throws -> [DNSRecord] {
        if let error {
            throw error
        }
        return resolvedRecords[hostname] ?? []
    }

    public func setResolvedIPv4(_ resolved: [String], for unresolved: String) {
        resolvedRecords[unresolved] = resolved.map {
            DNSRecord(address: $0, isIPv6: false)
        }
    }

    public func setResolvedIPv6(_ resolved: [String], for unresolved: String) {
        resolvedRecords[unresolved] = resolved.map {
            DNSRecord(address: $0, isIPv6: true)
        }
    }
}
