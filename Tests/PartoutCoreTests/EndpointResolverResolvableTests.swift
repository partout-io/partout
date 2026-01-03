// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct EndpointResolverResolvableTests {
    @Test
    func givenEndpoint_whenResolve_thenCyclesThroughResolved() async throws {
        let hostname = "some.hostname.com"
        let proto = EndpointProtocol(.tcp, 12345)
        let endpoint = try ExtendedEndpoint(hostname, proto)
        let resolvedRecords = [
            DNSRecord(address: "1.1.1.1", isIPv6: false),
            DNSRecord(address: "2.2.2.2", isIPv6: false),
            DNSRecord(address: "3.3.3.3", isIPv6: false)
        ]

        let dns = MockDNSResolver()
        dns.resolvedRecords = [hostname: resolvedRecords]
        var sut = EndpointResolver.Resolvable(.global, endpoint)

        sut = try await sut.resolved(with: dns, timeout: 1000)
        #expect(sut.isResolved)

        for (i, record) in resolvedRecords.enumerated() {
            let endpoint = try ExtendedEndpoint(record.address, proto)
            #expect(sut.currentEndpoint == endpoint)
            guard let next = sut.withNextEndpoint() else {
                #expect(i == resolvedRecords.count - 1)
                break
            }
            sut = next
        }
    }

    @Test
    func givenEndpoint_whenFailToResolve_thenReturnsNoEndpoint() async throws {
        let proto = EndpointProtocol(.tcp, 12345)

        let endpoint = try ExtendedEndpoint("some.hostname.com", proto)
        let dns = MockDNSResolver()
        dns.error = PartoutError(.dnsFailure)
        var sut = EndpointResolver.Resolvable(.global, endpoint)

        do {
            sut = try await sut.resolved(with: dns, timeout: 1000)
        } catch {
            sut = sut.with(newResolvedEndpoints: [])
        }
        #expect(sut.isResolved)
        #expect(sut.currentEndpoint == nil)
    }
}
