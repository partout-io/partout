// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct EndpointResolverTests {
    @Test
    func givenEndpoints_whenCycle_thenPicksNext() async throws {
        let hostname = "some.hostname.com"
        let dns = MockDNSResolver()
        dns.resolvedRecords = [
            hostname: [
                DNSRecord(address: "111:bbbb:ffff::eeee", isIPv6: true),
                DNSRecord(address: "11.22.33.44", isIPv6: false)
            ]
        ]
        var sut = resolver(
            hostname: hostname,
            protocols: [
                EndpointProtocol(.tcp6, 2222),
                EndpointProtocol(.udp, 1111),
                EndpointProtocol(.udp4, 3333)
            ]
        )

        let expected = [
            "111:bbbb:ffff::eeee:TCP6:2222",
            "111:bbbb:ffff::eeee:UDP:1111",
            "11.22.33.44:UDP:1111",
            "11.22.33.44:UDP4:3333"
        ]
        var i = 0
        do {
            while true {
                let result = try await sut.withNextEndpoint(dns: dns, timeout: 1000)
                sut = result.nextResolver
                #expect(result.endpoint.description == expected[i])
                i += 1
            }
        } catch {
            //
        }
    }

    @Test
    func givenIPv4Endpoints_whenCycle_thenPicksNextIPv4() async throws {
        let hostname = "some.hostname.com"
        let dns = MockDNSResolver()
        dns.resolvedRecords = [
            hostname: [
                DNSRecord(address: "111:bbbb:ffff::eeee", isIPv6: true),
                DNSRecord(address: "11.22.33.44", isIPv6: false)
            ]
        ]
        var sut = resolver(
            hostname: hostname,
            protocols: [
                EndpointProtocol(.tcp4, 2222)
            ]
        )

        let expected = [
            "11.22.33.44:TCP4:2222"
        ]
        var i = 0
        do {
            while true {
                let result = try await sut.withNextEndpoint(dns: dns, timeout: 1000)
                sut = result.nextResolver
                #expect(result.endpoint.description == expected[i])
                i += 1
            }
        } catch {
            //
        }
    }

    @Test
    func givenIPv6Endpoints_whenCycle_thenPicksNextIPv6() async throws {
        let hostname = "some.hostname.com"
        let dns = MockDNSResolver()
        dns.resolvedRecords = [
            hostname: [
                DNSRecord(address: "111:bbbb:ffff::eeee", isIPv6: true),
                DNSRecord(address: "11.22.33.44", isIPv6: false)
            ]
        ]
        var sut = resolver(
            hostname: hostname,
            protocols: [
                EndpointProtocol(.udp6, 2222)
            ]
        )

        let expected = [
            "111:bbbb:ffff::eeee:UDP6:2222"
        ]
        var i = 0
        do {
            while true {
                let result = try await sut.withNextEndpoint(dns: dns, timeout: 1000)
                sut = result.nextResolver
                #expect(result.endpoint.description == expected[i])
                i += 1
            }
        } catch {
            //
        }
    }

    @Test
    func givenEndpoints_whenResolve_thenReturnsResolvedLinks() async throws {
        let hostname = "some.hostname.com"
        let protocols: [EndpointProtocol] = [
            EndpointProtocol(.udp, 1000),
            EndpointProtocol(.udp, 2000),
            EndpointProtocol(.udp, 3000)
        ]
        let endpoints: [ExtendedEndpoint] = protocols.compactMap {
            try? .init(hostname, $0)
        }
        let resolvables = endpoints.map {
            EndpointResolver.Resolvable(.global, $0)
        }
        var sut = EndpointResolver(.global, resolvables: resolvables)

        let dns = MockDNSResolver()
        dns.resolvedRecords = [
            hostname: [
                DNSRecord(address: "5.5.5.5", isIPv6: false),
                DNSRecord(address: "10.10.10.10", isIPv6: false),
                DNSRecord(address: "30.30.30.30", isIPv6: false)
            ]
        ]

        let expected = [
            try? ExtendedEndpoint("5.5.5.5", EndpointProtocol(.udp, 1000)),
            try? ExtendedEndpoint("10.10.10.10", EndpointProtocol(.udp, 1000)),
            try? ExtendedEndpoint("30.30.30.30", EndpointProtocol(.udp, 1000)),
            try? ExtendedEndpoint("5.5.5.5", EndpointProtocol(.udp, 2000)),
            try? ExtendedEndpoint("10.10.10.10", EndpointProtocol(.udp, 2000)),
            try? ExtendedEndpoint("30.30.30.30", EndpointProtocol(.udp, 2000)),
            try? ExtendedEndpoint("5.5.5.5", EndpointProtocol(.udp, 3000)),
            try? ExtendedEndpoint("10.10.10.10", EndpointProtocol(.udp, 3000)),
            try? ExtendedEndpoint("30.30.30.30", EndpointProtocol(.udp, 3000))
        ].compactMap { $0 }

        var i = 0
        do {
            while true {
                let result = try await sut.withNextEndpoint(dns: dns, timeout: 1000)
                sut = result.nextResolver
                #expect(result.endpoint == expected[i])
                i += 1
            }
        } catch {
            //
        }
    }
}

// MARK: - Helpers

private extension EndpointResolverTests {
    func resolver(
        hostname: String,
        protocols: [EndpointProtocol]
    ) -> EndpointResolver {
        let endpoints: [ExtendedEndpoint] = protocols.compactMap {
            try? .init(hostname, $0)
        }
        let resolvables = endpoints.map {
            EndpointResolver.Resolvable(.global, $0)
        }
        return EndpointResolver(.global, resolvables: resolvables)
    }
}
