// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Resolve peers of the given tunnel configuration.
/// - Parameter tunnelConfiguration: tunnel configuration.
/// - Throws: an error of type `WireGuardAdapterError`.
/// - Returns: The list of resolved endpoints.
extension WireGuard.Configuration {
    actor ResolvedMap {
        private let preferringIPv4: Bool
        private var map: [Address: [Endpoint]] = [:]

        init(preferringIPv4: Bool) {
            self.preferringIPv4 = preferringIPv4
        }

        func setEndpoints(_ endpoints: [Endpoint], for address: Address) {
            assert(!endpoints.isEmpty, "Assigning empty resolved endpoints")
            if preferringIPv4 {
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
                map = [address: [targetEndpoint]]
            } else {
                map = [address: endpoints]
            }
        }

        func toMap() -> [Address: [Endpoint]] {
            map
        }
    }

    func resolvePeers(
        preferringIPv4: Bool,
        timeout: Int,
        logHandler: @escaping WireGuardAdapter.LogHandler
    ) async -> [Address: [Endpoint]] {
        let endpoints = peers.compactMap(\.endpoint)
        let resolver = SimpleDNSResolver {
            POSIXDNSStrategy(hostname: $0)
        }
        return await withTaskGroup(returning: [Address: [Endpoint]].self) { group in
            let allResolved = ResolvedMap(preferringIPv4: preferringIPv4)
            for endpoint in endpoints {
                group.addTask { @Sendable in
                    do {
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
                        await allResolved.setEndpoints(currentResolved, for: endpoint.address)
                    } catch {
                        logHandler(.error, "Failed to resolve endpoint \(endpoint.address.asSensitiveAddress(.global)): \(error.localizedDescription)")
                    }
                }
            }
            await group.waitForAll()
            return await allResolved.toMap()
        }
    }
}
