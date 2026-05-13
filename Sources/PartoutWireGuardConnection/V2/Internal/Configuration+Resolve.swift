// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Resolve peers of the given tunnel configuration.
/// - Parameter tunnelConfiguration: tunnel configuration.
/// - Throws: an error of type `WireGuardAdapterError`.
/// - Returns: The list of resolved endpoints.
extension WireGuard.Configuration {
    actor ResolvedMap {
        private var map: [Endpoint: Endpoint] = [:]

        private var failures: [Endpoint] = []

        func setEndpoints(_ endpoints: [Endpoint], for sourceEndpoint: Endpoint) {
            assert(!endpoints.isEmpty, "Assigning empty resolved endpoints")
            let targetEndpoint: Endpoint? = {
                // All resolved IPv4 addresses
                let allV4 = endpoints.filter {
                    $0.address.family == .v4
                }
                // Pick first IPv4 address if any
                if let firstV4 = allV4.first {
                    return firstV4
                }
                // Pick first address otherwise (expect IPv6, never hostname)
                guard let firstEndpoint = endpoints.first else { return nil }
                assert(firstEndpoint.address.family == .v6)
                return firstEndpoint
            }()
            guard let targetEndpoint else { return }
            map[sourceEndpoint] = targetEndpoint
        }

        func setFailure(for endpoint: Endpoint) {
            failures.append(endpoint)
        }

        func toMap() -> [Endpoint: Endpoint] {
            map
        }

        func failedEndpoints() -> [Endpoint] {
            failures
        }
    }

    func resolvePeers(
        timeout: Int,
        logHandler: @escaping WireGuardAdapter.LogHandler
    ) async throws -> [Endpoint: Endpoint] {
        let resolver = SimpleDNSResolver {
            POSIXDNSStrategy(hostname: $0, flags: Self.dnsResolverFlags)
        }
        return try await resolvePeers(
            timeout: timeout,
            logHandler: logHandler,
            resolver: resolver
        )
    }

    func resolvePeers(
        timeout: Int,
        logHandler: @escaping WireGuardAdapter.LogHandler,
        resolver: DNSResolver
    ) async throws -> [Endpoint: Endpoint] {
        let endpoints = peers.compactMap(\.endpoint)
        return try await withThrowingTaskGroup(of: Void.self, returning: [Endpoint: Endpoint].self) { group in
            let allResolved = ResolvedMap()
            for endpoint in endpoints {
                group.addTask { @Sendable in
                    do {
                        if endpoint.address.isIPAddress {
                            logHandler(.verbose, "DNS64: mapped \(endpoint.address) to itself.")
                            await allResolved.setEndpoints([endpoint], for: endpoint)
                            return
                        }
                        let resolvedRecords = try await resolver.resolve(
                            endpoint.address.rawValue,
                            timeout: timeout
                        )
                        var currentResolved: [Endpoint] = []
                        for record in resolvedRecords {
                            let newEndpoint = try Endpoint(record.address, endpoint.port)
                            guard !currentResolved.contains(newEndpoint) else { continue }
                            currentResolved.append(newEndpoint)
                            if record.address == endpoint.address.rawValue {
                                logHandler(.verbose, "DNS64: mapped \(endpoint.address) to itself.")
                            } else {
                                logHandler(.verbose, "DNS64: mapped \(endpoint.address) to \(record.address)")
                            }
                        }
                        guard !currentResolved.isEmpty else {
                            await allResolved.setFailure(for: endpoint)
                            return
                        }
                        await allResolved.setEndpoints(currentResolved, for: endpoint)
                    } catch {
                        logHandler(.error, "Failed to resolve endpoint \(endpoint.address.asSensitiveAddress(.global)): \(error.localizedDescription)")
                        await allResolved.setFailure(for: endpoint)
                    }
                }
            }
            try await group.waitForAll()
            let failures = await allResolved.failedEndpoints()
            guard failures.isEmpty else {
                throw WireGuardAdapterError.dnsResolution(failures)
            }
            return await allResolved.toMap()
        }
    }

    private static var dnsResolverFlags: Int32 {
#if canImport(Darwin)
        AI_ALL
#else
        0
#endif
    }
}
