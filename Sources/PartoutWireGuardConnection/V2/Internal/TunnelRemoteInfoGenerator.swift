// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

internal import _PartoutWireGuard_C

final class TunnelRemoteInfoGenerator: @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    let tunnelConfiguration: WireGuard.Configuration

    let resolvedEndpoints: [Endpoint: Endpoint]

    init(
        _ ctx: PartoutLoggerContext,
        tunnelConfiguration: WireGuard.Configuration,
        resolvedEndpoints: [Endpoint: Endpoint]
    ) {
        self.ctx = ctx
        self.tunnelConfiguration = tunnelConfiguration
        self.resolvedEndpoints = resolvedEndpoints
    }

    convenience init(
        _ ctx: PartoutLoggerContext,
        tunnelConfiguration: WireGuard.Configuration,
        dnsTimeout: Int
    ) {
        self.init(ctx, tunnelConfiguration: tunnelConfiguration, resolvedEndpoints: [:])
    }

    func endpointUapiConfiguration(logHandler: WireGuardAdapter.LogHandler) -> String {
        var wgSettings = ""

        for peer in tunnelConfiguration.peers {
            let publicKey: String
            do {
                publicKey = try peer.publicKey.rawValue.hexStringFromBase64()
            } catch {
                pp_log(ctx, .wireguard, .error, "Unable to parse peer public key: \(peer.publicKey.rawValue)")
                continue
            }
            wgSettings.append("public_key=\(publicKey)\n")

            guard let endpoint = peer.endpoint,
                  let resolvedEndpoint = resolvedEndpoints[endpoint] else {
                continue
            }
            if case .hostname = resolvedEndpoint.address {
                assertionFailure("Endpoint is not resolved")
            }
            logEndpointResolution(endpoint, resolvedEndpoint, logHandler: logHandler)
            wgSettings.append("endpoint=\(resolvedEndpoint.wgRepresentation)\n")
        }

        return wgSettings
    }

    func uapiConfiguration(logHandler: WireGuardAdapter.LogHandler) throws -> String {
        var wgSettings = ""
        wgSettings.append("private_key=\(try tunnelConfiguration.interface.privateKey.rawValue.hexStringFromBase64())\n")
        // TODO: #93, listenPort not implemented
//        if let listenPort = tunnelConfiguration.interface.listenPort {
//            wgSettings.append("listen_port=\(listenPort)\n")
//        }
        if !tunnelConfiguration.peers.isEmpty {
            wgSettings.append("replace_peers=true\n")
        }

        for peer in tunnelConfiguration.peers {
            wgSettings.append("public_key=\(try peer.publicKey.rawValue.hexStringFromBase64())\n")
            if let preSharedKeyBase64 = peer.preSharedKey?.rawValue, !preSharedKeyBase64.isEmpty {
                wgSettings.append("preshared_key=\(try preSharedKeyBase64.hexStringFromBase64())\n")
            }

            if let endpoint = peer.endpoint,
               let resolvedEndpoint = resolvedEndpoints[endpoint] {
                if case .hostname = resolvedEndpoint.address {
                    assertionFailure("Endpoint is not resolved")
                }
                logEndpointResolution(endpoint, resolvedEndpoint, logHandler: logHandler)
                wgSettings.append("endpoint=\(resolvedEndpoint.wgRepresentation)\n")
            }

            let persistentKeepAlive = peer.keepAlive ?? 0
            wgSettings.append("persistent_keepalive_interval=\(persistentKeepAlive)\n")
            if !peer.allowedIPs.isEmpty {
                wgSettings.append("replace_allowed_ips=true\n")
                peer.allowedIPs.forEach {
                    guard !$0.rawValue.isEmpty else { return }
                    wgSettings.append("allowed_ip=\($0.rawValue)\n")
                }
            }
        }
        return wgSettings
    }

    func generateRemoteInfo(moduleId: UniqueID, descriptors: [Int32]) -> TunnelRemoteInfo {
        /* iOS requires a tunnel endpoint, whereas in WireGuard it's valid for
         * a tunnel to have no endpoint, or for there to be many endpoints, in
         * which case, displaying a single one in settings doesn't really
         * make sense. So, we fill it in with this placeholder, which is not
         * a valid IP address that will actually route over the Internet.
         */
        let remoteAddress = Address(rawValue: "127.0.0.1")
        assert(remoteAddress != nil)

        let (ipv4Addresses, ipv6Addresses) = addresses()
        let (ipv4IncludedRoutes, ipv6IncludedRoutes) = includedRoutes()
        let ipv4 = IPSettings(subnets: ipv4Addresses)
            .including(routes: ipv4IncludedRoutes)
        let ipv6 = IPSettings(subnets: ipv6Addresses)
            .including(routes: ipv6IncludedRoutes)

        let mtu: UInt16 = {
            guard let specified = tunnelConfiguration.interface.mtu,
                  specified > 0 else {
#if os(iOS) || os(tvOS)
                return 1280
#elseif os(macOS)
                return 1400
#else
                return 0
#endif
            }
            return specified
        }()
        let ipModule = IPModule.Builder(ipv4: ipv4, ipv6: ipv6, mtu: Int(mtu)).build()

        var modules: [Module] = []
        modules.append(ipModule)
        if let dns = tunnelConfiguration.interface.dns {
            modules.append(dns)
        }

#if os(Windows)
        let requiresVirtualDevice = false
#else
        let requiresVirtualDevice = true
#endif
        return TunnelRemoteInfo(
            originalModuleId: moduleId,
            address: remoteAddress,
            modules: modules,
            fileDescriptors: descriptors.map(UInt64.init),
            requiresVirtualDevice: requiresVirtualDevice
        )
    }

    private func logEndpointResolution(_ endpoint: Endpoint, _ resolvedEndpoint: Endpoint, logHandler: WireGuardAdapter.LogHandler) {
        if endpoint.address == resolvedEndpoint.address {
            logHandler(.verbose, "DNS64: mapped \(endpoint.address) to itself.")
        } else {
            logHandler(.verbose, "DNS64: mapped \(endpoint.address) to \(resolvedEndpoint.address)")
        }
    }
}

extension WireGuard.Configuration {
    actor ResolvedMap {
        private var map: [Endpoint: Endpoint] = [:]

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

        func toMap() -> [Endpoint: Endpoint] {
            map
        }
    }

    func resolvePeers(
        timeout: Int,
        logHandler: @escaping WireGuardAdapter.LogHandler
    ) async throws -> [Endpoint: Endpoint] {
        let endpoints = peers.compactMap(\.endpoint)
        let resolver = SimpleDNSResolver {
            POSIXDNSStrategy(hostname: $0)
        }
        return try await withThrowingTaskGroup(returning: [Endpoint: Endpoint].self) { group in
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
                        guard !currentResolved.isEmpty else {
                            throw PartoutError(.dnsFailure)
                        }
                        await allResolved.setEndpoints(currentResolved, for: endpoint)
                    } catch {
                        logHandler(.error, "Failed to resolve endpoint \(endpoint.address.asSensitiveAddress(.global)): \(error.localizedDescription)")
                        throw error
                    }
                }
            }
            do {
                try await group.waitForAll()
            } catch {
                throw WireGuardAdapterError.dnsResolution
            }
            return await allResolved.toMap()
        }
    }
}

private extension TunnelRemoteInfoGenerator {
    func addresses() -> ([Subnet], [Subnet]) {
        var ipv4: [Subnet] = []
        var ipv6: [Subnet] = []
        for subnet in tunnelConfiguration.interface.addresses {
            switch subnet.address {
            case .ip(_, let family):
                switch family {
                case .v4:
                    ipv4.append(subnet)
                case .v6:
                    guard let clampedSubnet = Subnet(subnet.address, min(120, subnet.prefixLength)) else {
                        fatalError("Could not clamp subnet prefix for WireGuard workaround")
                    }
                    ipv6.append(clampedSubnet)
                }
            default:
                break
            }
        }
        return (ipv4, ipv6)
    }

    func includedRoutes() -> ([Route], [Route]) {
        var ipv4IncludedRoutes: [Route] = []
        var ipv6IncludedRoutes: [Route] = []

        for subnet in tunnelConfiguration.interface.addresses {
            switch subnet.address {
            case .ip(_, let family):
                let route = Route(subnet.maskedSubnet, subnet.address)
                switch family {
                case .v4:
                    ipv4IncludedRoutes.append(route)
                case .v6:
                    ipv6IncludedRoutes.append(route)
                }
            default:
                break
            }
        }

        for peer in tunnelConfiguration.peers {
            for subnet in peer.allowedIPs {
                switch subnet.address {
                case .ip(_, let family):
                    let route = Route(subnet, nil)
                    switch family {
                    case .v4:
                        ipv4IncludedRoutes.append(route)
                    case .v6:
                        ipv6IncludedRoutes.append(route)
                    }
                default:
                    break
                }
            }
        }
        return (ipv4IncludedRoutes, ipv6IncludedRoutes)
    }
}

private extension Subnet {
    var maskedSubnet: Subnet {
        let maskedAddress: Address? = switch address.family {
        case .v4:
            address.network(with: ipv4Mask)
        case .v6:
            address.network(with: prefixLength)
        case nil:
            nil
        }
        guard let maskedAddress,
              let maskedSubnet = Subnet(maskedAddress, prefixLength) else {
            fatalError("Could not derive masked route subnet from interface address")
        }
        return maskedSubnet
    }
}

private extension Endpoint {
    var wgRepresentation: String {
        switch address.family {
        case .v6:
            return "[\(address.rawValue)]:\(port)"
        default:
            return "\(address.rawValue):\(port)"
        }
    }
}
