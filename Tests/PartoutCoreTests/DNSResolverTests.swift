// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct DNSResolverTests {
    @Test
    func givenResolver_whenResolve_thenReturnsResolvedAddress() throws {
        let expRecords = [DNSRecord(address: "1.2.3.4", isIPv6: false)]

        let sut = MockDNSResolver()
        sut.resolvedRecords = ["www.google.com": expRecords]
        let records = try sut.resolve("www.google.com", timeout: 1000)
        #expect(records == expRecords)
    }

    @Test
    func givenBrokenResolver_whenResolve_thenFails() throws {
        let sut = MockDNSResolver()
        sut.error = PartoutError(.dnsFailure)
        do {
            _ = try sut.resolve("www.google.com", timeout: 1000)
        } catch let error as PartoutError {
            #expect(error.code == .dnsFailure)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test
    func givenSlowResolver_whenResolve_thenFailsWithTimeout() throws {
        let sut = MockDNSResolver()
        sut.error = PartoutError(.timeout)
        do {
            _ = try sut.resolve("www.google.com", timeout: 1000)
        } catch let error as PartoutError {
            #expect(error.code == .timeout)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }
}
