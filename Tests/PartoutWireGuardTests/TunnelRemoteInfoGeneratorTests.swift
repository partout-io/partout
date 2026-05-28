// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutWireGuardConnection
import Testing

struct TunnelRemoteInfoGeneratorTests {
    @Test(arguments: [
        (["1.2.3.4", "22:4", "55:3:4::9f"], "1.2.3.4", "1.2.3.4"),
        (["22:4", "1.2.3.4", "55:3:4::9f"], "1.2.3.4", "22:4"),
        (["1.2.3.4", "5.6.7.8", "55:3:4::9f"], "1.2.3.4", "1.2.3.4"),
        (["1:2:3::4", "22:4", "55:3:4::9f"], "1:2:3::4", "1:2:3::4")
    ])
    func givenEndpoints_thenPrefersIPv4(
        endpoints: [String],
        targetIPv4: String,
        targetAny: String
    ) async throws {
        let sourceEndpoint = try Endpoint("foobar.com", 1080)
        let endpointObjects = try endpoints.map {
            try Endpoint($0, sourceEndpoint.port)
        }
        let targetIPv4Object = try Endpoint(targetIPv4, sourceEndpoint.port)

        let withEnabled = WireGuard.Configuration.ResolvedMap()
        await withEnabled.setEndpoints(endpointObjects, for: sourceEndpoint)
        let enabledMap = await withEnabled.toMap()
        #expect(enabledMap[sourceEndpoint] == targetIPv4Object)
    }

    @Test
    func givenSameHostnameWithDifferentPorts_whenResolved_thenKeepsBothPeers() async throws {
        let sourceEndpoint1 = try Endpoint("foobar.com", 1080)
        let sourceEndpoint2 = try Endpoint("foobar.com", 2080)
        let resolvedEndpoint1 = try Endpoint("1.2.3.4", sourceEndpoint1.port)
        let resolvedEndpoint2 = try Endpoint("5.6.7.8", sourceEndpoint2.port)

        let withEnabled = WireGuard.Configuration.ResolvedMap()
        await withEnabled.setEndpoints([resolvedEndpoint1], for: sourceEndpoint1)
        await withEnabled.setEndpoints([resolvedEndpoint2], for: sourceEndpoint2)
        let enabledMap = await withEnabled.toMap()

        #expect(enabledMap[sourceEndpoint1] == resolvedEndpoint1)
        #expect(enabledMap[sourceEndpoint2] == resolvedEndpoint2)
    }

    @Test
    func givenIPAddressEndpoint_whenResolved_thenBypassesDNS64Cache() async throws {
        let sourceEndpoint = try Endpoint("77.160.28.16", 51830)
        let configuration = try makeConfiguration(endpoint: sourceEndpoint.rawValue)
        let dns = RecordingDNSResolver()
        await dns.setResolvedRecords([
            DNSRecord(address: "64:ff9b::4da0:1c10", isIPv6: true)
        ], for: sourceEndpoint.address.rawValue)

        let map = try await configuration.resolvePeers(
            resolver: dns,
            timeout: 1000,
            logHandler: { _, _ in }
        )

        #expect(map[sourceEndpoint] == sourceEndpoint)
        let requestedHostnames = await dns.requestedHostnames
        #expect(requestedHostnames.isEmpty)
    }

    @Test
    func givenHostnameEndpointWithDNS64AndIPv4_whenResolved_thenCachesIPv4BaseAddress() async throws {
        let sourceEndpoint = try Endpoint("foobar.com", 51830)
        let ipv4Endpoint = try Endpoint("77.160.28.16", sourceEndpoint.port)
        let configuration = try makeConfiguration(endpoint: sourceEndpoint.rawValue)
        let dns = RecordingDNSResolver()
        await dns.setResolvedRecords([
            DNSRecord(address: "64:ff9b::4da0:1c10", isIPv6: true),
            DNSRecord(address: ipv4Endpoint.address.rawValue, isIPv6: false)
        ], for: sourceEndpoint.address.rawValue)

        let map = try await configuration.resolvePeers(
            resolver: dns,
            timeout: 1000,
            logHandler: { _, _ in }
        )

        #expect(map[sourceEndpoint] == ipv4Endpoint)
        let requestedHostnames = await dns.requestedHostnames
        #expect(requestedHostnames == [sourceEndpoint.address.rawValue])
    }

    @Test
    func givenCachedResolution_whenGeneratingEndpointUpdate_thenDoesNotResolveAgainUntilReset() async throws {
        let pvtkey = "SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs="
        let pubkey = "BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw="

        var builder = WireGuard.Configuration.Builder(privateKey: pvtkey)
        var peer = WireGuard.RemoteInterface.Builder(publicKey: pubkey)
        peer.endpoint = "127.0.0.1:12345"
        peer.allowedIPs = ["0.0.0.0/0"]
        builder.peers = [peer]

        let configuration = try builder.build()
        let sut = TunnelRemoteInfoGenerator(
            .global,
            tunnelConfiguration: configuration,
            dnsTimeout: 1000
        )
        let logs = LogCollector()
        let logHandler: WireGuardAdapter.LogHandler = { _, message in
            logs.append(message)
        }

        _ = try await sut.uapiConfiguration(logHandler: logHandler)
        let resolutionCountAfterFullConfiguration = logs.resolutionCount

        _ = await sut.endpointUapiConfiguration(logHandler: logHandler)
        let resolutionCountAfterEndpointUpdate = logs.resolutionCount

        #expect(resolutionCountAfterFullConfiguration > 0)
        #expect(resolutionCountAfterEndpointUpdate == resolutionCountAfterFullConfiguration)

        await sut.resetResolvedEndpoints()
        _ = try await sut.uapiConfiguration(logHandler: logHandler)
        let resolutionCountAfterReset = logs.resolutionCount

        #expect(resolutionCountAfterReset > resolutionCountAfterEndpointUpdate)
    }

    @Test
    func givenPeerWithoutEndpoint_whenGeneratingUAPIConfiguration_thenKeepsPeerSettings() async throws {
        let pvtkey = "SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs="
        let pubkey = "BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw="

        var builder = WireGuard.Configuration.Builder(privateKey: pvtkey)
        var peer = WireGuard.RemoteInterface.Builder(publicKey: pubkey)
        peer.allowedIPs = ["10.0.0.0/24"]
        peer.keepAlive = 25
        builder.peers = [peer]

        let configuration = try builder.build()
        let sut = TunnelRemoteInfoGenerator(
            .global,
            tunnelConfiguration: configuration,
            dnsTimeout: 1
        )

        let uapiConfiguration = try await sut.uapiConfiguration(logHandler: { _, _ in })

        #expect(!uapiConfiguration.contains("endpoint="))
        #expect(uapiConfiguration.contains("persistent_keepalive_interval=25"))
        #expect(uapiConfiguration.contains("replace_allowed_ips=true"))
        #expect(uapiConfiguration.contains("allowed_ip=10.0.0.0/24"))
    }

    @Test
    func givenInterfaceAddresses_whenGeneratingRemoteInfo_thenMasksInterfaceRoutes() throws {
        let pvtkey = "SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs="
        let pubkey = "BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw="

        var builder = WireGuard.Configuration.Builder(privateKey: pvtkey)
        builder.interface.addresses = [
            "10.0.0.2/24",
            "fd00::2/64"
        ]
        builder.peers = [.init(publicKey: pubkey)]

        let configuration = try builder.build()
        let sut = TunnelRemoteInfoGenerator(
            .global,
            tunnelConfiguration: configuration,
            dnsTimeout: 1
        )
        let info = sut.generateRemoteInfo(moduleId: UniqueID())
        let ipModule = try #require(info.modules?.compactMap { $0 as? IPModule }.first)

        #expect(ipModule.ipv4?.includedRoutes.first?.destination?.rawValue == "10.0.0.0/24")
        #expect(ipModule.ipv4?.includedRoutes.first?.gateway?.rawValue == "10.0.0.2")
        #expect(ipModule.ipv6?.includedRoutes.first?.destination?.rawValue == "fd00::/64")
        #expect(ipModule.ipv6?.includedRoutes.first?.gateway?.rawValue == "fd00::2")
    }
}

private func makeConfiguration(endpoint: String) throws -> WireGuard.Configuration {
    let pvtkey = "SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs="
    let pubkey = "BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw="

    var builder = WireGuard.Configuration.Builder(privateKey: pvtkey)
    var peer = WireGuard.RemoteInterface.Builder(publicKey: pubkey)
    peer.endpoint = endpoint
    peer.allowedIPs = ["0.0.0.0/0"]
    builder.peers = [peer]
    return try builder.build()
}

private actor RecordingDNSResolver: DNSResolver {
    private var resolvedRecords: [String: [DNSRecord]] = [:]

    private var hostnames: [String] = []

    func setResolvedRecords(_ records: [DNSRecord], for hostname: String) {
        resolvedRecords[hostname] = records
    }

    func resolve(_ hostname: String, timeout: Int) async throws -> [DNSRecord] {
        hostnames.append(hostname)
        return resolvedRecords[hostname] ?? []
    }

    var requestedHostnames: [String] {
        hostnames
    }
}

private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()

    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    var resolutionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return messages.filter {
            $0.hasPrefix("DNS64: mapped ")
        }.count
    }
}
