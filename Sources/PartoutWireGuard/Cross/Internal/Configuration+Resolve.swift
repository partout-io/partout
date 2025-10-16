// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOS
#endif

/// Resolve peers of the given tunnel configuration.
/// - Parameter tunnelConfiguration: tunnel configuration.
/// - Throws: an error of type `WireGuardAdapterError`.
/// - Returns: The list of resolved endpoints.
extension WireGuard.Configuration {
    private actor ResolvedMap {
        private var map: [Address: [Endpoint]] = [:]

        func setEndpoints(_ endpoints: [Endpoint], for address: Address) {
            map[address] = endpoints
        }

        func toMap() -> [Address: [Endpoint]] {
            map
        }
    }

    func resolvePeers(timeout: Int, logHandler: @escaping WireGuardAdapter.LogHandler) async -> [Address: [Endpoint]] {
        let endpoints = peers.compactMap(\.endpoint)
        let resolver = SimpleDNSResolver(strategy: {
            POSIXDNSStrategy(hostname: $0)
        })
        return await withTaskGroup(returning: [Address: [Endpoint]].self) { group in
            let allResolved = ResolvedMap()
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
                        logHandler(.error, "Failed to resolve endpoint \(endpoint.address): \(error.localizedDescription)")
                    }
                }
            }
            await group.waitForAll()
            return await allResolved.toMap()
        }
    }
}
