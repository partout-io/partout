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
    func resolvePeers(logHandler: @escaping WireGuardAdapter.LogHandler) async -> [Address: [Endpoint]] {
        let endpoints = peers.compactMap(\.endpoint)
        let resolver = SimpleDNSResolver(strategy: {
            POSIXDNSStrategy(hostname: $0)
        })
        return await withTaskGroup(returning: [Address: [Endpoint]].self) { group in
            nonisolated(unsafe) var allResolved: [Address: [Endpoint]] = [:]
            for endpoint in endpoints {
                group.addTask { @Sendable in
                    do {
                        // FIXME: #199, Pick WireGuard DNS timeout from ConnectionParameters
                        let resolvedRecords = try await resolver.resolve(endpoint.address.rawValue, timeout: 5000)
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
                        allResolved[endpoint.address] = currentResolved
                    } catch {
                        logHandler(.error, "Failed to resolve endpoint \(endpoint.address): \(error.localizedDescription)")
                    }
                }
            }
            await group.waitForAll()
            return allResolved
        }
    }
}
