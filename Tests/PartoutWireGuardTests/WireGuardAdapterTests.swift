// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutWireGuardConnection
import Testing

struct WireGuardAdapterTests {
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
        let address: Address = .hostname("foobar.com")
        let port: UInt16 = 1080
        let endpointObjects = try endpoints.map {
            try Endpoint($0, port)
        }
        let targetIPv4Object = try Endpoint(targetIPv4, port)

        let withEnabled = WireGuard.Configuration.ResolvedMap()
        await withEnabled.setEndpoints(endpointObjects, for: address)
        let enabledMap = await withEnabled.toMap()
        #expect(enabledMap[address] == [targetIPv4Object])
    }
}
