// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutVendorsApple
import Foundation
import PartoutCore
import Testing

struct CFDNSResolverTests {
    @Test(.disabled())
    func givenResolver_whenResolveBeforeTimeout_thenReturnsResolvedRecords() async throws {
        let hostname = "fixed.it"
        let records = [DNSRecord(address: "5.9.152.28", isIPv6: false)]
        let sut = SimpleDNSResolver {
            CFDNSStrategy(hostname: $0)
        }
        let result = try await sut.resolve(hostname, timeout: 1000)
        #expect(result == records)
    }

    @Test(.disabled())
    func givenResolver_whenResolveAfterTimeout_thenFailsWithTimeout() async throws {
        let hostname = "fixed.it"
        let sut = SimpleDNSResolver {
            CFDNSStrategy(hostname: $0)
        }
        do {
            _ = try await sut.resolve(hostname, timeout: 1)
            #expect(Bool(false), ".resolve must fail")
        } catch let error as PartoutError {
            #expect(error.code == .dnsFailure)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }
}
