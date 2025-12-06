// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutWireGuard
import Testing

struct WireGuardAdapterTests {
    @Test(arguments: [
        (["1.2.3.4", "22:4", "55:3:4::9f"], "1.2.3.4", "1.2.3.4"),
        (["22:4", "1.2.3.4", "55:3:4::9f"], "1.2.3.4", "22:4"),
        (["1.2.3.4", "5.6.7.8", "55:3:4::9f"], "1.2.3.4", "1.2.3.4"),
        (["1:2:3::4", "22:4", "55:3:4::9f"], "1:2:3::4", "1:2:3::4")
    ])
    func givenEndpoints_whenPreferredIPv4_thenReturnsIPv4(
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
        let targetAnyObject = try Endpoint(targetAny, port)

        let withEnabled = newMap(preferringIPv4: true)
        await withEnabled.setEndpoints(endpointObjects, for: address)
        let enabledMap = await withEnabled.toMap()
        #expect(enabledMap[address] == [targetIPv4Object])

        let withDisabled = newMap(preferringIPv4: false)
        await withDisabled.setEndpoints(endpointObjects, for: address)
        let disabledMap = await withDisabled.toMap()
        #expect(disabledMap[address] == endpointObjects)
        #expect(disabledMap[address]?.first == targetAnyObject)
    }

    private func newMap(preferringIPv4: Bool) -> WireGuard.Configuration.ResolvedMap {
        WireGuard.Configuration.ResolvedMap(preferringIPv4: preferringIPv4)
    }
}
